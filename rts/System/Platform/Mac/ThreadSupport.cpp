/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#include "System/Platform/Threading.h"
#include "System/Log/ILog.h"
#include <memory>
#include <pthread/qos.h>
#include <pthread.h>
#include <cstdint>
#include <mach/mach.h>

namespace Threading {

void SetupCurrentThreadControls(std::shared_ptr<ThreadControls>& threadCtls)
{
	threadCtls.reset(new Threading::ThreadControls());
	threadCtls->handle = pthread_self();

	// macOS has no pthread_setaffinity_np equivalent, so threads cannot be
	// pinned to performance cores the way the Linux path does. Hint the
	// scheduler instead: USER_INTERACTIVE is the highest QoS tier and
	// strongly prefers the performance cluster on Apple Silicon. Only a
	// thread that sets up its controls gets it: today the main thread, the
	// game-load thread and the file-system scan thread. The thread pool's
	// workers, the audio thread and the net thread do not come through
	// here and keep the QoS they were created with.
	const qos_class_t prev = qos_class_self();
	pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
	// the process logs its own promotions (reading another process's QoS
	// needs root)
	LOG("[Threading] QoS 0x%x -> USER_INTERACTIVE (thread %p)",
			(unsigned)prev, (void*)pthread_self());
}

void ThreadStart(
	std::function<void()> taskFunc,
	std::shared_ptr<ThreadControls>* threadCtls,
	ThreadControls* tempCtls)
{
	if (threadCtls != nullptr) {
		SetupCurrentThreadControls(*threadCtls);
	}

	// notify the caller that this thread is running
	{
		std::lock_guard<spring::mutex> lock(tempCtls->mutSuspend);
		tempCtls->condInitialized.notify_one();
	}

	taskFunc();
}

// Not used on macOS: the watchdog reads a hung thread's frames with
// CaptureThreadStack below, which suspends and resumes the thread itself.
SuspendResult ThreadControls::Suspend()
{
	return Threading::THREADERR_NOT_RUNNING;
}

SuspendResult ThreadControls::Resume()
{
	return Threading::THREADERR_NONE;
}

// Return addresses of another thread, innermost first, for the watchdog's hang
// report. The thread is suspended, its registers are read, and the chain of
// frame records on its stack is followed (arm64 keeps one per function: the
// caller's frame pointer, then the return address). Nothing between suspend
// and resume allocates or takes a lock, because the suspended thread may hold
// either. A function that has not built its frame yet (a system call stub, for
// one) hides its direct caller; the frames above it are still right.
int CaptureThreadStack(NativeThreadHandle thread, void** ips, int maxDepth)
{
#if defined(__arm64__)
	if (maxDepth <= 0 || pthread_equal(thread, pthread_self()))
		return 0;

	const mach_port_t port = pthread_mach_thread_np(thread);
	const uintptr_t stackTop = reinterpret_cast<uintptr_t>(pthread_get_stackaddr_np(thread));
	const uintptr_t stackBottom = stackTop - pthread_get_stacksize_np(thread);

	if (thread_suspend(port) != KERN_SUCCESS)
		return 0;

	int n = 0;
	arm_thread_state64_t state;
	mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;

	if (thread_get_state(port, ARM_THREAD_STATE64, reinterpret_cast<thread_state_t>(&state), &count) == KERN_SUCCESS) {
		ips[n++] = reinterpret_cast<void*>(static_cast<uintptr_t>(arm_thread_state64_get_pc(state)));
		uintptr_t fp = arm_thread_state64_get_fp(state);

		while (n < maxDepth && fp >= stackBottom && (fp + 2 * sizeof(uintptr_t)) <= stackTop && (fp & 0xf) == 0) {
			const uintptr_t* record = reinterpret_cast<const uintptr_t*>(fp);
			const uintptr_t callerFp = record[0];
			const uintptr_t returnAddr = record[1];

			if (returnAddr == 0)
				break;
			ips[n++] = reinterpret_cast<void*>(returnAddr);
			if (callerFp <= fp)
				break;
			fp = callerFp;
		}
	}

	thread_resume(port);
	return n;
#else
	return 0;
#endif
}

} // namespace Threading
