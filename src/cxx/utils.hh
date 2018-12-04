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
//   TOMOPY class header

#ifndef utils_hh_
#define utils_hh_

//============================================================================//

#include <cstdint>
#include <iomanip>
#include <iostream>
#include <ostream>
#include <sstream>
#include <string>
#include <vector>

#ifdef TOMOPY_USE_TIMEMORY
#    include <timemory/timemory.hpp>
#else
#    include "profiler.hh"
#endif

#include "gpu.hh"

#include "PTL/AutoLock.hh"
#include "PTL/TaskManager.hh"
#include "PTL/TaskRunManager.hh"
#include "PTL/ThreadData.hh"
#include "PTL/Threading.hh"
#include "PTL/Utility.hh"

#if !defined(cast)
#    define cast static_cast
#endif

#if !defined(PRINT_HERE)
#    define PRINT_HERE(extra)                                                  \
        printf("[%lu]> %s@'%s':%i %s\n", ThreadPool::GetThisThreadID(),        \
               __FUNCTION__, __FILE__, __LINE__, extra)
#endif

#if !defined(NUM_TASK_THREADS)
#    define NUM_TASK_THREADS Thread::hardware_concurrency()
#endif

#if defined(DEBUG)
#    define PRINT_MAX_ITER 1
#    define PRINT_MAX_SLICE 1
#    define PRINT_MAX_ANGLE 1
#    define PRINT_MAX_PIXEL 5
#else
#    define PRINT_MAX_ITER 1
#    define PRINT_MAX_SLICE 1
#    define PRINT_MAX_ANGLE 1
#    define PRINT_MAX_PIXEL 5
#endif

//============================================================================//

struct GpuOption
{
    int         index;
    std::string key;
    std::string description;

    static void spacer(std::ostream& os, const char c = '-')
    {
        std::stringstream ss;
        ss.fill(c);
        ss << std::setw(90) << ""
           << "\n";
        os << ss.str();
    }

    static void header(std::ostream& os)
    {
        std::stringstream ss;
        ss << "\n";
        spacer(ss, '=');
        ss << "Available GPU options:\n";
        ss << "\t" << std::left << std::setw(5) << "INDEX"
           << "  \t" << std::left << std::setw(12) << "KEY"
           << "  " << std::left << std::setw(40) << "DESCRIPTION"
           << "\n";
        os << ss.str();
    }

    static void footer(std::ostream& os)
    {
        std::stringstream ss;
        ss << "\nTo select an option for runtime, set TOMOPY_GPU_TYPE "
           << "environment variable\n  to an INDEX or KEY above\n";
        spacer(ss, '=');
        os << ss.str();
    }

    friend std::ostream& operator<<(std::ostream& os, const GpuOption& opt)
    {
        std::stringstream ss;
        ss << "\t" << std::right << std::setw(5) << opt.index << "  \t"
           << std::left << std::setw(12) << opt.key << "  " << std::left
           << std::setw(40) << opt.description;
        os << ss.str();
        return os;
    }
};

//============================================================================//

template <typename _Tp>
_Tp
from_string(const std::string& val)
{
    std::stringstream ss;
    _Tp               ret;
    ss << val;
    ss >> ret;
    return ret;
}

//============================================================================//

inline std::string
tolower(std::string val)
{
    for(uintmax_t i = 0; i < val.size(); ++i) val[i] = tolower(val[i]);
    return val;
}

//============================================================================//

inline void
init_thread_data(ThreadPool* tp)
{
    ThreadData*& thread_data = ThreadData::GetInstance();
    if(!thread_data)
        thread_data = new ThreadData(tp);
    thread_data->is_master   = false;
    thread_data->within_task = false;
}

//============================================================================//

template <typename _Tp>
void
print_cpu_array(const uintmax_t& n, const _Tp* data, const int& itr,
                const int& slice, const int& angle, const int& pixel,
                const std::string& tag)
{
    std::ofstream     ofs;
    std::stringstream fname;
    fname << "outputs/cpu/" << tag << "_" << itr << "_" << slice << "_" << angle
          << "_" << pixel << ".dat";
    ofs.open(fname.str().c_str());
    if(!ofs)
        return;
    for(uintmax_t i = 0; i < n; ++i)
        ofs << std::setw(6) << i << " \t " << std::setw(12)
            << std::setprecision(8) << data[i] << std::endl;
    ofs.close();
}

//============================================================================//

typedef std::vector<float> farray_t;
typedef std::vector<int>   iarray_t;

//============================================================================//

struct AngleData
{
    AngleData()
    : s(0)
    , p(0)
    , d(0)
    , csize(0)
    , sum_dist_sqr(0.0f)
    , indi(nullptr)
    , dist(nullptr)
    {
    }

    // _ngrid == ngridx + ngridy
    AngleData(int _s, int _p, int _d, int _csize, const int& _ngrid)
    : s(_s)
    , p(_p)
    , d(_d)
    , csize(_csize)
    , sum_dist_sqr(0.0f)
    , indi(new iarray_t(_ngrid))
    , dist(new farray_t(_ngrid))
    {
    }

    ~AngleData()
    {
        delete indi;
        delete dist;
    }

    int       s;
    int       p;
    int       d;
    int       csize;
    float     sum_dist_sqr;
    iarray_t* indi;
    farray_t* dist;
};

typedef std::vector<AngleData*> AngleDataArray;

//============================================================================//

inline TaskRunManager*&
cpu_run_manager()
{
    static TaskRunManager* _instance = new TaskRunManager(
        GetEnv<bool>("TOMOPY_USE_TBB", false, "Enable TBB backend"));
    return _instance;
}

//============================================================================//

inline TaskRunManager*&
gpu_run_manager()
{
    AutoLock               l(TypeMutex<TaskRunManager>());
    static TaskRunManager* _instance = new TaskRunManager(
        GetEnv<bool>("TOMOPY_USE_TBB", false, "Enable TBB backend"));
    return _instance;
}

//============================================================================//

inline Mutex&
update_mutex()
{
    static Mutex _instance;
    return _instance;
}

//============================================================================//

inline void
init_run_manager(TaskRunManager*& run_man, uintmax_t nthreads)
{
    auto tid = ThreadPool::GetThisThreadID();
    ConsumeParameters(tid);

    {
        AutoLock l(TypeMutex<TaskRunManager>());
        if(!run_man->IsInitialized())
        {
            std::cout << "\n"
                      << "[" << tid
                      << "] Initializing CPU task run manager with " << nthreads
                      << " threads..." << std::endl;
            run_man->Initialize(nthreads);
        }
    }
    TaskManager* task_man = run_man->GetTaskManager();
    ThreadPool*  tp       = task_man->thread_pool();
    init_thread_data(tp);

    if(GetEnv<int>("TASKING_VERBOSE", 0) > 0)
    {
        AutoLock l(TypeMutex<decltype(std::cout)>());
        std::cout << "> art::" << __FUNCTION__ << "@" << __LINE__ << " -- "
                  << "run manager = " << run_man << ", "
                  << "task manager = " << task_man << ", "
                  << "thread pool = " << tp << ", "
                  << "..." << std::endl;
    }
}

//============================================================================//

void DLL
     cxx_preprocessing(int ry, int rz, int num_pixels, float center, float& mov,
                       farray_t& gridx, farray_t& gridy);

//============================================================================//

void DLL
     cxx_calc_coords(int ry, int rz, float xi, float yi, float sin_p, float cos_p,
                     const farray_t& gridx, const farray_t& gridy, farray_t& coordx,
                     farray_t& coordy);

//============================================================================//

void DLL
     cxx_trim_coords(int ry, int rz, const farray_t& coordx, const farray_t& coordy,
                     const farray_t& gridx, const farray_t& gridy, farray_t& ax,
                     farray_t& ay, farray_t& bx, farray_t& by);

//============================================================================//

void DLL
     cxx_sort_intersections(const int& ind_condition, const farray_t& ax,
                            const farray_t& ay, const farray_t& bx,
                            const farray_t& by, int& csize, farray_t& coorx,
                            farray_t& coory);

//============================================================================//

float DLL
      cxx_calc_sum_sqr(const farray_t& dist);

//============================================================================//

void DLL
     cxx_calc_dist(int ry, int rz, int csize, const farray_t& coorx,
                   const farray_t& coory, iarray_t& indi, farray_t& dist);

//============================================================================//

void DLL
     cxx_calc_dist2(int ry, int rz, int csize, const farray_t& coorx,
                    const farray_t& coory, iarray_t& indx, iarray_t& indy,
                    farray_t& dist);

//============================================================================//

void DLL
     cxx_calc_simdata(int s, int p, int d, int ry, int rz, int dt, int dx, int csize,
                      const iarray_t& indi, const farray_t& dist, const float* model,
                      farray_t& simdata);

//============================================================================//

void DLL
     cxx_calc_simdata2(int s, int p, int d, int ry, int rz, int dt, int dx,
                       int csize, const iarray_t& indx, const iarray_t& indy,
                       const farray_t& dist, float vx, float vy,
                       const farray_t& modelx, const farray_t& modely,
                       farray_t& simdata);

//============================================================================//

void DLL
     cxx_calc_simdata3(int s, int p, int d, int ry, int rz, int dt, int dx,
                       int csize, const iarray_t& indx, const iarray_t& indy,
                       const farray_t& dist, float vx, float vy,
                       const farray_t& modelx, const farray_t& modely,
                       const farray_t& modelz, int axis, farray_t& simdata);

//============================================================================//

#endif
