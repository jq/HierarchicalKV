/*
* Copyright (c) 2024, NVIDIA CORPORATION.
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

#include <gtest/gtest.h>
//#include "merlin/core_kernels/reserved_bucket.cuh"
#include "test_util.cuh"
#include <iostream>
#include <cassert>
#include <cuda_runtime.h>

#include "merlin/allocator.cuh"
#include "merlin/types.cuh"

using namespace nv::merlin;

typedef uint64_t K;
typedef float V;

#define RESERVED_BUCKET_SIZE 4
#define RESERVED_BUCKET_MASK 3

template <class K, class V> struct RdBucket;

template <class K, class V>
__global__ static void rb_size_kernel(RdBucket<K, V>* reserved_bucket, size_t* size);

template <class K, class V>
struct RdBucket {
  cuda::atomic<bool, cuda::thread_scope_device> locks[RESERVED_BUCKET_SIZE];
  bool keys[RESERVED_BUCKET_SIZE];
  static void initialize(RdBucket<K, V>** reserved_bucket,
                         BaseAllocator* allocator, size_t dim) {
    size_t total_size = sizeof (RdBucket<K, V>);
    total_size += sizeof(V) * RESERVED_BUCKET_SIZE * dim;
    void* memory_block;
    allocator->alloc(MemoryType::Device, &memory_block, total_size);
    CUDA_CHECK(cudaMemset(memory_block, 0, total_size));
    *reserved_bucket = static_cast<RdBucket<K, V>*>(memory_block);
  }

  __forceinline__ __device__ V* get_vector(K key, size_t dim) {
    V* vector = reinterpret_cast<V*>(keys + RESERVED_BUCKET_SIZE);
    size_t index = key & RESERVED_BUCKET_MASK;
    return vector + index * dim;
  }

  __forceinline__ __device__ bool contains(K key) {
    size_t index = key & RESERVED_BUCKET_MASK;
    return keys[index];
  }

  __forceinline__ __device__ void set_key(K key, bool value = true) {
    size_t index = key & RESERVED_BUCKET_MASK;
    keys[index] = value;
  }

  // since reserved bucket key should always exist
  // insert_or_assign insert_and_evict assign all equal to write_vector
  __forceinline__ __device__ void write_vector(
      K key, size_t dim, const V* data) {
    V* vectors = get_vector(key, dim);
    set_key(key);
    for (int i = 0; i < dim; i++) {
      vectors[i] = data[i];
      printf("vectors[%d] = %f  %f \n", i, vectors[i], data[i]);
    }
  }

  __forceinline__ __device__ void read_vector(
      K key, size_t dim, V* out_data) {
    V* vectors = get_vector(key, dim);
    for (int i = 0; i < dim; i++) {
      out_data[i] = vectors[i];
        printf("out_data[%d] = %f  %f \n", i, out_data[i], vectors[i]);
    }
  }

  __forceinline__ __device__ void erase(K key, size_t dim) {
    V* vectors = get_vector(key, dim);
    set_key(key, false);
    for (int i = 0; i < dim; i++) {
      vectors[i] = 0;
    }
  }

  // Search for the specified keys and return the pointers of values.
  __forceinline__ __device__ bool find(K key, size_t dim, V** values) {
    if (contains(key)) {
      V* vectors = get_vector(key, dim);
      *values = vectors;
      return true;
    } else {
      return false;
    }
  }

  // Search for the specified keys and Insert them firstly when missing.
  __forceinline__ __device__ bool find_or_insert(K key, size_t dim, V* values) {
    if (contains(key)) {
      return true;
    } else {
      write_vector(key, dim, values);
      set_key(key);
      return false;
    }
  }

  // Search for the specified keys and return the pointers of values.
  // Insert them firstly when missing.
  __forceinline__ __device__ bool find_or_insert(
      K key, size_t dim, V** values) {
    if (contains(key)) {
      V* vectors = get_vector(key, dim);
      *values = vectors;
      return true;
    } else {
      write_vector(key, dim, *values);
      set_key(key);
      return false;
    }
  }
  __forceinline__ __device__ void accum_or_assign(
      K key, bool is_accum, size_t dim, const V* values) {
    if (is_accum) {
      V* vectors = get_vector(key, dim);
      for (int i = 0; i < dim; i++) {
        vectors[i] += values[i];
      }
    } else {
      write_vector(key, dim, values);
    }
    set_key(key);
  }

  /*
    * @brief Exports reserved bucket to key-value tuples
    * @param n The maximum number of exported pairs.
    * @param offset The position of the key to search.
    * @param keys The keys to dump from GPU-accessible memory with shape (n).
    * @param values The values to dump from GPU-accessible memory with shape
    * (n, DIM).
   * @return The number of elements dumped.
   */
  __forceinline__ __device__ size_t export_batch(
      size_t n, const size_t offset,
      K* keys, size_t dim, V* values, size_t batch_size) {
    if (offset >= size()) {
      return 0;
    }

    size_t count = 0;
    V* vector = reinterpret_cast<V*>(keys + RESERVED_BUCKET_SIZE);
    for (int i = offset; i < RESERVED_BUCKET_SIZE && offset < n; i++) {
      vector += i * dim;
      offset++;
      if (keys[i]) {
        for (int j = 0; j < dim; j++) {
          values[i * dim + j] = vector[j];
        }
      }
    }
    return count;
  }

  /**
   * @brief Returns the reserved bucket size.
   */
  __forceinline__ __device__ size_t size() {
    size_t count = 0;
    for (int i = 0; i < RESERVED_BUCKET_SIZE; i++) {
      if (keys[i]) {
        count++;
      }
    }
    return count;
  }

  size_t size_host() {
    size_t * d_size;
    cudaMalloc(&d_size, sizeof(int));
    rb_size_kernel<<<1, 1>>>(this, d_size);
    CUDA_CHECK(cudaDeviceSynchronize());
    int h_size;
    cudaMemcpy(&h_size, d_size, sizeof(int), cudaMemcpyDeviceToHost);
    CUDA_CHECK(cudaFree(d_size));
    return h_size;
  }
  /**
   * @brief Removes all of the elements in the reserved bucket with no release
   * object.
   */
  __forceinline__ __device__ void clear(size_t dim) {
    size_t total_size = sizeof (RdBucket<K, V>);
    total_size += sizeof(V) * RESERVED_BUCKET_SIZE * dim;
    CUDA_CHECK(cudaMemset(this, 0, total_size));
  }
};

template <class K, class V>
__global__ static void rb_size_kernel(RdBucket<K, V>* reserved_bucket, size_t* size) {
  *size = reserved_bucket->size();
}

template <class K, class V>
__global__ void rb_write_vector_kernel(RdBucket<K, V>* reserved_bucket,
                                    K key, size_t dim, const V* data) {
  reserved_bucket->write_vector(key, dim, data);
}

template <class K, class V>
__global__ void rb_read_vector_kernel(RdBucket<K, V>* reserved_bucket,
                                   K key, size_t dim, V* out_data) {
  reserved_bucket->read_vector(key, dim, out_data);
}

template <class K, class V>
__global__ void rb_erase_kernel(RdBucket<K, V>* reserved_bucket,
                                     K key, size_t dim) {
  reserved_bucket->erase(key, dim);
}

template <class K, class V>
__global__ void rb_clear_kernel(RdBucket<K, V>* reserved_bucket, size_t dim) {
  reserved_bucket->clear(dim);
}

template <class K, class V>
__global__ void rb_find_or_insert_kernel(
    RdBucket<K, V>* reserved_bucket,
    K key, size_t dim, const V* data, bool* is_found) {
  *is_found = reserved_bucket->find_or_insert(key, dim, data);
}

template <class K, class V> __global__ void rb_find_or_insert_kernel(
    RdBucket<K, V>* reserved_bucket, K key, size_t dim, bool* is_found, V** values) {
  *is_found = reserved_bucket->find_or_insert(key, dim, values);
}

template <class K, class V>
__global__ void rb_accum_or_assign_kernel(
    RdBucket<K, V>* reserved_bucket,
    K key, bool is_accum,
    size_t dim, const V* data) {
  printf("rb_accum_or_assign_kernel\n");
  reserved_bucket->accum_or_assign(key, is_accum, dim, data);
}

template <class K, class V> __global__ void rb_find_kernel(
        RdBucket<K, V>* reserved_bucket, K key, size_t dim,
    bool* found, V** values) {
  *found = reserved_bucket->find(key, dim, values);
}

template <class K, class V> __global__ void rb_export_batch_kernel(
    RdBucket<K, V>* reserved_bucket, size_t n, size_t offset, K* keys,
    size_t dim, V* values, size_t batch_size) {
  reserved_bucket->export_batch(n, offset, keys, dim, values, batch_size);
}

#include <cstdlib>
void print_vector(const float* vector, size_t dim) {
  std::cout << "Vector contents: [";
  for (size_t i = 0; i < dim; i++) {
    std::cout << vector[i] << (i < dim - 1 ? ", " : "");
  }
  std::cout << "]" << std::endl;
}

#define ASSERT_EQUAL(x, y, index) \
    do { \
        if ((x) != (y)) { \
            std::cerr << "Assertion failed: (" << #x << " == " << #y \
                      << "), in file " << __FILE__ << ", line " << __LINE__ \
                      << ", index " << (index) << ".\n" \
                      << "Values: " << (x) << " != " << (y) << std::endl; \
            std::abort(); \
        } \
    } while (false)

bool find_key(RdBucket<K, V>* bucket, K key, size_t dim, V* values) {
  bool* d_is_found;
  cudaMalloc(&d_is_found, sizeof(bool));
  V** d_values;
  cudaMalloc(&d_values, sizeof(V*));
  rb_find_kernel<<<1, 1>>>(bucket, key, dim, d_is_found, d_values);
  CUDA_CHECK(cudaDeviceSynchronize());
  bool h_is_found;
  CUDA_CHECK(cudaMemcpy(&h_is_found, d_is_found, sizeof(bool), cudaMemcpyDeviceToHost));
  std::cout << "found " << h_is_found <<std::endl;
  if (h_is_found) {
    V* h_values;
    cudaMalloc(&h_values, sizeof(V*));
    CUDA_CHECK(cudaMemcpy(&h_values, d_values, sizeof(V*), cudaMemcpyDeviceToHost));
    CUDA_CHECK(cudaMemcpy(values, h_values, sizeof(V)*dim, cudaMemcpyDeviceToHost));
  }
  CUDA_CHECK(cudaFree(d_is_found));
  CUDA_CHECK(cudaFree(d_values));
  return h_is_found;
}

void array_eq(const V* a, const V* b, size_t dim) {
  for (size_t i = 0; i < dim; i++) {
    ASSERT_EQUAL(a[i], b[i], i);
  }
}

void test_reserved_bucket_gpu(K key) {
  std::shared_ptr<DefaultAllocator> default_allocator(new DefaultAllocator());
  BaseAllocator* allocator = default_allocator.get();
  int num_devices;
  CUDA_CHECK(cudaGetDeviceCount(&num_devices));
  MERLIN_CHECK(num_devices > 0,
               "Need at least one CUDA capable device for running this test.");
  std::cout << "enter " << key % RESERVED_BUCKET_SIZE << std::endl;
  RdBucket<K, V>* bucket;
  size_t dim = 10;
  RdBucket<K, V>::initialize(&bucket, allocator, dim);

  V* test_vector;
  V* out_vector;
  CUDA_CHECK(cudaMalloc(&test_vector, dim * sizeof(V)));
  CUDA_CHECK(cudaMalloc(&out_vector, dim * sizeof(V)));

  V host_vector[10] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9};
  CUDA_CHECK(cudaMemcpy(test_vector, host_vector,
                        dim * sizeof(V), cudaMemcpyHostToDevice));

  CudaCheckError();

  rb_write_vector_kernel<<<1, 1>>>(bucket, key, dim, test_vector);

  CUDA_CHECK(cudaDeviceSynchronize());
  assert(bucket->size_host() == 1);
  V host_out_vector[10];
  bool found = find_key(bucket, key, dim, host_out_vector);
  assert(found);
  array_eq(host_vector, host_out_vector, dim);

  rb_read_vector_kernel<<<1, 1>>>(bucket, key, dim, out_vector);

  CUDA_CHECK(cudaDeviceSynchronize());

  CUDA_CHECK(cudaMemcpy(
     host_out_vector, out_vector, dim * sizeof(V), cudaMemcpyDeviceToHost));

  print_vector(host_out_vector, dim);
  array_eq(host_vector, host_out_vector, dim);

  rb_erase_kernel<<<1, 1>>>(bucket, key, dim);
  CUDA_CHECK(cudaDeviceSynchronize());
  rb_read_vector_kernel<<<1, 1>>>(bucket, key, dim, out_vector);
  CUDA_CHECK(cudaMemcpy(
      host_out_vector, out_vector, dim * sizeof(V), cudaMemcpyDeviceToHost));
  CUDA_CHECK(cudaDeviceSynchronize());
  for (int i = 0; i < dim; i++) {
    ASSERT_EQUAL(host_out_vector[i], 0, i);
  }
  assert(bucket->size_host() == 0);
  assert(!find_key(bucket, key, dim, host_out_vector));

  rb_accum_or_assign_kernel<<<1, 1>>>(bucket, key, false, dim, test_vector);
  CUDA_CHECK(cudaDeviceSynchronize());

  assert(bucket->size_host() == 1);
  assert(find_key(bucket, key, dim, host_out_vector));
  array_eq(host_vector, host_out_vector, dim);

  rb_accum_or_assign_kernel<<<1, 1>>>(bucket, key, true, dim, test_vector);
  CUDA_CHECK(cudaDeviceSynchronize());
  assert(bucket->size_host() == 1);
  assert(find_key(bucket, key, dim, host_out_vector));

  V host_vector2[10] = {0, 2, 4, 6, 8, 10, 12, 14, 16, 18};
  array_eq(host_vector2, host_out_vector, dim);
  std::cout << "All GPU tests passed!" << std::endl;

  CUDA_CHECK(cudaFree(test_vector));
  CUDA_CHECK(cudaFree(out_vector));
  CudaCheckError();
}

TEST(RdBucketTest, test_reserved_bucket_gpu) {
  test_reserved_bucket_gpu(EMPTY_KEY);
  test_reserved_bucket_gpu(RECLAIM_KEY);
  test_reserved_bucket_gpu(LOCKED_KEY);
  test_reserved_bucket_gpu(RESERVED_KEY_MASK);
}