//  Copyright (c) 2015, UChicago Argonne, LLC. All rights reserved.
//  Copyright 2015. UChicago Argonne, LLC. This software was produced
//  under U.S. Government contract DE-AC02-06CH11357 for Argonne National
//  Laboratory (ANL), which is operated by UChicago Argonne, LLC for the
//  U.S. Department of Energy. The U.S. Government has rights to use,
//  reproduce, and distribute this software.  NEITHER THE GOVERNMENT NOR
//  UChicago Argonne, LLC MAKES ANY WARRANTY, EXPRESS OR IMPLIED, OR
//  ASSUMES ANY LIABILITY FOR THE USE OF THIS SOFTWARE.  If software is
//  modified to produce derivative works, such modified software should
//  be clearly marked, so as not to confuse it with the version available
//  from ANL.
//  Additionally, redistribution and use in source and binary forms, with
//  or without modification, are permitted provided that the following
//  conditions are met:
//      * Redistributions of source code must retain the above copyright
//        notice, this list of conditions and the following disclaimer.
//      * Redistributions in binary form must reproduce the above copyright
//        notice, this list of conditions and the following disclaimer in
//        the documentation andwith the
//        distribution.
//      * Neither the name of UChicago Argonne, LLC, Argonne National
//        Laboratory, ANL, the U.S. Government, nor the names of its
//        contributors may be used to endorse or promote products derived
//        from this software without specific prior written permission.
//  THIS SOFTWARE IS PROVIDED BY UChicago Argonne, LLC AND CONTRIBUTORS
//  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
//  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
//  FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL UChicago
//  Argonne, LLC OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
//  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
//  BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
//  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
//  CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
//  LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
//  ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
//  POSSIBILITY OF SUCH DAMAGE.
//  ---------------------------------------------------------------
//   TOMOPY CUDA implementation

#include "common.hh"
#include "gpu.hh"
#include "utils.hh"
#include "utils_cuda.hh"

BEGIN_EXTERN_C
#include "sirt.h"
#include "utils.h"
#include "utils_openacc.h"
#include "utils_openmp.h"
END_EXTERN_C

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <memory>
#include <numeric>

//======================================================================================//

#if defined(TOMOPY_USE_NVTX)
extern nvtxEventAttributes_t nvtx_total;
extern nvtxEventAttributes_t nvtx_iteration;
extern nvtxEventAttributes_t nvtx_slice;
extern nvtxEventAttributes_t nvtx_projection;
extern nvtxEventAttributes_t nvtx_update;
extern nvtxEventAttributes_t nvtx_rotate;
#endif

//======================================================================================//

typedef gpu_data::int_type     int_type;
typedef gpu_data::init_data_t  init_data_t;
typedef gpu_data::data_array_t data_array_t;

//======================================================================================//

__global__ void
cuda_sirt_pixels_kernel(int p, int nx, int dx, float* recon, const float* data,
                        const int_type* recon_use, float* sum_dist)
{
    int d0      = blockIdx.x * blockDim.x + threadIdx.x;
    int dstride = blockDim.x * gridDim.x;

    for(int d = d0; d < dx; d += dstride)
    {
        int   fnx = 0;
        float sum = 0.0f;
        for(int i = 0; i < nx; ++i)
            sum += recon[d * nx + i];
        for(int i = 0; i < nx; ++i)
        {
            if(recon_use[d * nx + i] > 0)
            {
                fnx += 1;
                sum_dist[d * nx + i] += 1.0f;
            }
        }

        float upd = (data[p * dx + d] - sum);
        if(upd == upd)  // is finite
            for(int i = 0; i < nx; ++i)
                recon[d * nx + i] += upd;
    }
}

//======================================================================================//

__global__ void
cuda_sirt_update_kernel(float* recon, const float* update, const float* sum_dist, int dx,
                        int size)
{
    int i0      = blockIdx.x * blockDim.x + threadIdx.x;
    int istride = blockDim.x * gridDim.x;

    float fdx = scast<float>(dx);
    for(int i = i0; i < size; i += istride)
    {
        if(sum_dist[i] != 0.0f)
            atomicAdd(&recon[i], update[i] / sum_dist[i] / fdx);
    }
}

//======================================================================================//

void
sirt_gpu_compute_projection(data_array_t& _gpu_data, int s, int p, int dy, int dt, int dx,
                            int nx, int ny, const float* theta)
{
    auto _cache = _gpu_data[GetThisThreadID() % _gpu_data.size()];

#if defined(DEBUG)
    printf("[%lu] Running slice %i, projection %i on device %i...\n", GetThisThreadID(),
           s, p, _cache->device());
#endif

    // ensure running on proper device
    cuda_set_device(_cache->device());

    // calculate some values
    float        theta_p_rad = fmodf(theta[p] + halfpi, twopi);
    float        theta_p_deg = theta_p_rad * degrees;
    const float* data        = _cache->data() + s * dt * dx;
    const float* recon       = _cache->recon() + s * nx * ny;
    float*       update      = _cache->update() + s * nx * ny;
    float*       sum_dist    = _cache->sum_dist() + s * nx * ny;
    auto*        use_rot     = _cache->use_rot();
    auto*        use_tmp     = _cache->use_tmp();
    float*       rot         = _cache->rot();
    float*       tmp         = _cache->tmp();
    int          smem        = 0;
    const float  factor      = 1.0f;
    int          block       = _cache->block();
    int          grid        = _cache->compute_grid(nx);
    cudaStream_t stream      = _cache->stream();

    gpu_memset<int_type>(use_rot, 0, nx * ny, stream);
    gpu_memset<float>(rot, 0, nx * ny, stream);
    gpu_memset<float>(tmp, 0, nx * ny, stream);

    // forward-rotate
    cuda_rotate_ip(use_rot, use_tmp, -theta_p_rad, -theta_p_deg, nx, ny, stream, GPU_NN);
    cuda_rotate_ip(rot, recon, -theta_p_rad, -theta_p_deg, nx, ny, stream);
    // compute simdata
    cuda_sirt_pixels_kernel<<<grid, block, smem, stream>>>(p, nx, dx, rot, data, use_rot,
                                                           sum_dist);
    // back-rotate
    cuda_rotate_ip(tmp, rot, theta_p_rad, theta_p_deg, nx, ny, stream);
    // update shared update array
    cuda_atomic_sum_kernel<<<grid, block, smem, stream>>>(update, tmp, nx * ny, factor);
    // synchronize the stream (do this frequently to avoid backlog)
    stream_sync(stream);
}

//--------------------------------------------------------------------------------------//

void
sirt_cuda(const float* cpu_data, int dy, int dt, int dx, const float* center,
          const float* theta, float* cpu_recon, int ngridx, int ngridy, int num_iter)
{
    typedef decltype(HW_CONCURRENCY) nthread_type;

    auto num_devices = cuda_device_count();
    if(num_devices == 0)
        throw std::runtime_error("No CUDA device(s) available");

    printf("[%lu]> %s : nitr = %i, dy = %i, dt = %i, dx = %i, nx = %i, ny = %i\n",
           GetThisThreadID(), __FUNCTION__, num_iter, dy, dt, dx, ngridx, ngridy);

    // initialize nvtx data
    init_nvtx();
    // print device info
    cuda_device_query();
    // thread counter for device assignment
    static std::atomic<int> ntid;

    // compute some properties (expected python threads, max threads, device assignment)
    auto min_threads = nthread_type(1);
    auto pythreads   = GetEnv("TOMOPY_PYTHON_THREADS", HW_CONCURRENCY);
    auto max_threads = HW_CONCURRENCY / std::max(pythreads, min_threads);
    auto nthreads    = std::max(GetEnv("TOMOPY_NUM_THREADS", max_threads), min_threads);
    int  device      = (ntid++) % num_devices;  // assign to device

#if defined(TOMOPY_USE_PTL)
    typedef TaskManager manager_t;
    TaskRunManager*     run_man = gpu_run_manager();
    init_run_manager(run_man, nthreads);
    TaskManager* task_man = run_man->GetTaskManager();
    ThreadPool*  tp       = task_man->thread_pool();
#else
    typedef void manager_t;
    void*        task_man = nullptr;
#endif

    TIMEMORY_AUTO_TIMER("");

    // GPU allocated copies
    cuda_set_device(device);
    printf("[%lu] Running on device %i...\n", GetThisThreadID(), device);

    uintmax_t    recon_pixels = scast<uintmax_t>(dy * ngridx * ngridy);
    auto         block        = GetBlockSize();
    auto         grid         = ComputeGridSize(recon_pixels, block);
    auto         main_stream  = create_streams(1);
    float*       update    = gpu_malloc_and_memset<float>(recon_pixels, 0, *main_stream);
    float*       sum_dist  = gpu_malloc_and_memset<float>(recon_pixels, 0, *main_stream);
    init_data_t  init_data = gpu_data::initialize(device, nthreads, dy, dt, dx, ngridx,
                                                 ngridy, cpu_recon, cpu_data);
    data_array_t _gpu_data = std::get<0>(init_data);
    float*       recon     = std::get<1>(init_data);
    const float* data      = std::get<2>(init_data);
    for(auto& itr : _gpu_data)
        itr->alloc_sum_dist();

    NVTX_RANGE_PUSH(&nvtx_total);

    for(int i = 0; i < num_iter; i++)
    {
        // timing and profiling
        TIMEMORY_AUTO_TIMER("");
        NVTX_RANGE_PUSH(&nvtx_iteration);
        START_TIMER(t_start);

        // sync the main stream
        stream_sync(*main_stream);

        // reset global update and sum_dist
        gpu_memset(update, 0, recon_pixels, *main_stream);
        gpu_memset(sum_dist, 0, recon_pixels, *main_stream);

        // sync and reset
        gpu_data::sync(_gpu_data);
        gpu_data::reset(_gpu_data);

        // execute the loop over slices and projection angles
        execute<manager_t, data_array_t>(task_man, dy, dt, std::ref(_gpu_data),
                                         sirt_gpu_compute_projection, dy, dt, dx, ngridx,
                                         ngridy, theta);

        // sync the thread streams
        gpu_data::sync(_gpu_data);

        // sync the main stream
        stream_sync(*main_stream);

        // have threads add to global update and sum_dist
        for(auto& itr : _gpu_data)
        {
            int block = itr->block();
            int grid  = itr->compute_grid(recon_pixels);
            cuda_atomic_sum_kernel<<<grid, block, 0, itr->stream(0)>>>(update,
                                                                       itr->update(),
                                                                       recon_pixels,
                                                                       1.0f);
            cuda_atomic_sum_kernel<<<grid, block, 0, itr->stream(1)>>>(sum_dist,
                                                                       itr->sum_dist(),
                                                                       recon_pixels,
                                                                       1.0f);
        }

        // sync the thread streams
        gpu_data::sync(_gpu_data);

        // update the global recon with global update and sum_dist
        cuda_sirt_update_kernel<<<grid, block, 0, *main_stream>>>(recon, update, sum_dist,
                                                                  dx, recon_pixels);

        // stop profile range and report timing
        NVTX_RANGE_POP(0);
        REPORT_TIMER(t_start, "iteration", i, num_iter);
    }

    // sync the main stream
    stream_sync(*main_stream);

    gpu2cpu_memcpy_and_free<float>(cpu_recon, recon, recon_pixels, *main_stream);

    // sync the main stream
    stream_sync(*main_stream);

    // destroy main stream
    destroy_streams(main_stream, 1);

    NVTX_RANGE_POP(0);
}

//======================================================================================//