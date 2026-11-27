//! Which processors our own threads run on, where a processor has two kinds
//! of cores. `cpu_sets` and `keep_on_fast_cores` are fxceless/victory-fork's
//! (`framelog.rs`, commit 0b0074e0, GPL-3.0-or-later, as this).

/// The system's processor sets of group 0: each one's id, its efficiency
/// class (higher is faster) and its logical processor's number.
fn cpu_sets() -> Vec<(u32, u8, u8)> {
    use windows_sys::Win32::System::SystemInformation::{GetSystemCpuSetInformation, SYSTEM_CPU_SET_INFORMATION};
    use windows_sys::Win32::System::Threading::GetCurrentProcess;
    let mut bytes = 0u32;
    // SAFETY: a size query, then the call into a buffer of that size.
    unsafe { GetSystemCpuSetInformation(std::ptr::null_mut(), 0, &mut bytes, GetCurrentProcess(), 0) };
    let mut buffer = vec![0u64; (bytes as usize).div_ceil(8).max(1)];
    // SAFETY: as above; the buffer holds `bytes` bytes, aligned for the records.
    let ok = unsafe { GetSystemCpuSetInformation(buffer.as_mut_ptr().cast(), bytes, &mut bytes, GetCurrentProcess(), 0) };
    let mut sets = Vec::new();
    let mut at = 0usize;
    while ok != 0 && at + size_of::<SYSTEM_CPU_SET_INFORMATION>() <= bytes as usize {
        // SAFETY: a record inside the buffer; each says its own size.
        let info = unsafe { &*(buffer.as_ptr().cast::<u8>().add(at).cast::<SYSTEM_CPU_SET_INFORMATION>()) };
        if info.Size == 0 {
            break;
        }
        // SAFETY: the record's type is CpuSet (the only one there is).
        let set = unsafe { &info.Anonymous.CpuSet };
        if set.Group == 0 {
            sets.push((set.Id, set.EfficiencyClass, set.LogicalProcessorIndex));
        }
        at += info.Size as usize;
    }
    sets
}

/// The last-level caches of group 0: each one's bytes and the mask of the
/// logical processors that share it.
fn l3_caches() -> Vec<(u32, u64)> {
    use windows_sys::Win32::System::SystemInformation::GetLogicalProcessorInformationEx;
    const RELATION_CACHE: i32 = 2;
    let mut bytes = 0u32;
    // SAFETY: a size query, then the call into a buffer of that size.
    unsafe { GetLogicalProcessorInformationEx(RELATION_CACHE, std::ptr::null_mut(), &mut bytes) };
    let mut buffer = vec![0u64; (bytes as usize).div_ceil(8).max(1)];
    // SAFETY: as above; the buffer holds `bytes` bytes, aligned for the records.
    let ok = unsafe { GetLogicalProcessorInformationEx(RELATION_CACHE, buffer.as_mut_ptr().cast(), &mut bytes) };
    let raw = buffer.as_ptr().cast::<u8>();
    let read = |at: usize, n: usize| -> u64 {
        let mut v = 0u64;
        for i in 0..n {
            // SAFETY: inside the `bytes` the call wrote (checked by the caller).
            v |= u64::from(unsafe { *raw.add(at + i) }) << (8 * i);
        }
        v
    };
    let mut caches = Vec::new();
    let mut at = 0usize;
    // A record: relationship (4), size (4), then CACHE_RELATIONSHIP: level
    // (1), associativity (1), line size (2), cache size (4), type (4), 18
    // reserved, group count (2), then GROUP_AFFINITY: mask (8), group (2).
    while ok != 0 && at + 50 <= bytes as usize {
        let size = read(at + 4, 4) as usize;
        if size == 0 {
            break;
        }
        let (level, cache, group) = (read(at + 8, 1), read(at + 12, 4) as u32, read(at + 48, 2));
        if level == 3 && group == 0 {
            caches.push((cache, read(at + 40, 8)));
        }
        at += size;
    }
    caches
}

/// The sets the threads a frame waits for are asked to run on, if not all of
/// them: of the fastest class, where there are slower ones; else, where the
/// last-level caches differ in size (AMD's X3D parts: one die with the
/// stacked cache, one without), those under the largest
/// (`VICTORY_CACHE_CORES=0`: not).
fn fast_of(sets: &[(u32, u8, u8)], l3: &[(u32, u64)]) -> Vec<u32> {
    let best = sets.iter().map(|c| c.1).max().unwrap_or(0);
    let fast: Vec<u32> = sets.iter().filter(|c| c.1 == best).map(|c| c.0).collect();
    if fast.len() != sets.len() {
        return fast;
    }
    if std::env::var_os("VICTORY_CACHE_CORES").is_some_and(|v| v == "0") {
        return Vec::new();
    }
    let (Some(most), Some(least)) = (l3.iter().map(|c| c.0).max(), l3.iter().map(|c| c.0).min()) else {
        return Vec::new();
    };
    if most == least {
        return Vec::new();
    }
    let mask = l3.iter().filter(|c| c.0 == most).fold(0u64, |m, c| m | c.1);
    let rich: Vec<u32> = sets.iter().filter(|c| c.2 < 64 && mask >> c.2 & 1 != 0).map(|c| c.0).collect();
    if rich.is_empty() || rich.len() == sets.len() { Vec::new() } else { rich }
}

/// `VICTORY_FAST_CORES`: 0: no thread asks; 1: the threads a frame waits for
/// one by one; 2 (the default): the threads they share their work with too;
/// 3: those that work beside the rest as well (lists translated, descriptors
/// made): more threads by then than the fast cores run at a time, while the
/// slow ones stood idle.
fn stage() -> u32 {
    static STAGE: std::sync::OnceLock<u32> = std::sync::OnceLock::new();
    *STAGE.get_or_init(|| std::env::var("VICTORY_FAST_CORES").ok().and_then(|v| v.trim().parse().ok()).unwrap_or(2))
}

/// Asks the system to run the calling thread, which a frame waits for, on
/// the fast cores only, where the processor has two kinds. That fork's submit
/// thread was found on a slow one in 1,529 looks of 24,021. (A selection of
/// processors is a preference the scheduler keeps unless nothing of it is
/// free.) The title's threads are not asked for.
pub(crate) fn keep_on_fast_cores(what: &str) {
    ask(what, 1);
}

/// [`keep_on_fast_cores`] for one of the threads a submission's preparing or
/// a landing shares its work with.
pub(crate) fn keep_helper_on_fast_cores(what: &str) {
    ask(what, 2);
}

/// [`keep_on_fast_cores`] for one of many threads whose work is ahead of what
/// a frame waits for.
pub(crate) fn keep_many_on_fast_cores(what: &str) {
    ask(what, 3);
}

/// The priority our own threads that a frame waits for, and those they share
/// their work with, run at (`VICTORY_HELPER_PRIORITY=<n>`, a thread priority
/// from -2 to 2; not given: as made, normal, the submitting thread above
/// normal). A frame's timeline in the first gameplay area (run timeline,
/// 2026-11-26) had such threads woken and not running yet for 4-11 ms of its
/// chain: the listing threads up to 5.4 ms at a time, while the title's own
/// workers held every processor.
fn helper_priority() -> Option<i32> {
    static PRIORITY: std::sync::OnceLock<Option<i32>> = std::sync::OnceLock::new();
    *PRIORITY.get_or_init(|| {
        std::env::var("VICTORY_HELPER_PRIORITY").ok().and_then(|v| v.trim().parse::<i32>().ok()).map(|p| p.clamp(-2, 2))
    })
}

fn ask(what: &str, from: u32) {
    use windows_sys::Win32::System::Threading::{GetCurrentThread, SetThreadPriority, SetThreadSelectedCpuSets};
    if let Some(priority) = helper_priority() {
        // SAFETY: this thread's own priority.
        let set = unsafe { SetThreadPriority(GetCurrentThread(), priority) } != 0;
        tracing::debug!(what, priority, set, "the thread's priority (VICTORY_HELPER_PRIORITY)");
    }
    if stage() < from {
        return;
    }
    static FAST: std::sync::OnceLock<(Vec<u32>, usize)> = std::sync::OnceLock::new();
    let (fast, of) = FAST.get_or_init(|| {
        let sets = cpu_sets();
        (fast_of(&sets, &l3_caches()), sets.len())
    });
    // All alike (or nothing known): nothing to ask for.
    if fast.is_empty() {
        return;
    }
    // SAFETY: our own thread and a list of the system's own set ids.
    let ok = unsafe { SetThreadSelectedCpuSets(GetCurrentThread(), fast.as_ptr(), fast.len() as u32) };
    if ok == 0 {
        tracing::warn!(what, error = %std::io::Error::last_os_error(), "the thread could not be kept on the fast cores");
    } else {
        tracing::info!(what, fast = fast.len(), of, "the thread is kept on the fast cores (VICTORY_FAST_CORES=0: not)");
    }
}

/// Whether the threads the submitting thread waits for run at its priority
/// (`VICTORY_HELPER_PRIORITY`, on unless `0`; `VICTORY_AB` can flip it while
/// the title runs): above normal, ahead of the title's threads and of the
/// threads that translate lists. They are the threads that spread its work
/// (`shadow::wide`, the pools of `land`), the one that makes the heaps'
/// records and the one that passes over the heap's views beside the lists.
///
/// On a processor with six cores (i5-12400F, 12 threads) the title's threads
/// and eight translating lists kept every core busy, and the submitting
/// thread (above normal since `queue::behind`) stood waiting for helpers at
/// normal priority that were not running. Measured with `VICTORY_AB` in one
/// run (run10, Series S at 540p, medians of 5-second windows in the world,
/// off / on): 8.6 / 9.6 fps, refreshes 23.1 / 17.6 ms a frame, waiting for
/// the heaps' records 6.2 / 2.5 ms, the card idle behind the submitting
/// thread 24.7 / 13.2 ms. Lowering the translating threads below normal as
/// well made each list call about 5 % slower, with no clear gain of its own.
fn helpers_raised() -> bool {
    crate::toggled!("VICTORY_HELPER_PRIORITY")
}

/// A helper's priority ([`helpers_raised`]). [`Self::keep`] is called before
/// each piece of work; it asks the system only when the switch has changed.
pub(crate) struct Priority {
    applied: Option<bool>,
}

impl Priority {
    pub(crate) fn new() -> Self {
        let mut priority = Self { applied: None };
        priority.keep();
        priority
    }

    pub(crate) fn keep(&mut self) {
        use windows_sys::Win32::System::Threading::{
            GetCurrentThread, SetThreadPriority, THREAD_PRIORITY_ABOVE_NORMAL, THREAD_PRIORITY_NORMAL,
        };
        let on = helpers_raised();
        if self.applied == Some(on) {
            return;
        }
        let priority = if on { THREAD_PRIORITY_ABOVE_NORMAL } else { THREAD_PRIORITY_NORMAL };
        // SAFETY: our own thread.
        unsafe { SetThreadPriority(GetCurrentThread(), priority) };
        self.applied = Some(on);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_fast_cores_are_those_of_the_best_class_if_there_is_a_worse_one() {
        assert_eq!(fast_of(&[(256, 1, 0), (257, 1, 1), (258, 0, 2)], &[]), [256, 257]);
        assert!(fast_of(&[(256, 0, 0), (257, 0, 1)], &[]).is_empty());
        assert!(fast_of(&[], &[]).is_empty());
        assert!(!cpu_sets().is_empty());
        let _ = l3_caches();
    }

    #[test]
    fn on_one_class_the_cores_under_the_largest_last_level_cache_are_asked_for() {
        let sets = [(256, 0, 0), (257, 0, 1), (258, 0, 2), (259, 0, 3)];
        // 96 MB under processors 0 and 1, 32 MB under 2 and 3 (an X3D part).
        assert_eq!(fast_of(&sets, &[(96 << 20, 0b0011), (32 << 20, 0b1100)]), [256, 257]);
        // Caches alike: nothing to ask for.
        assert!(fast_of(&sets, &[(32 << 20, 0b0011), (32 << 20, 0b1100)]).is_empty());
        assert!(fast_of(&sets, &[(32 << 20, 0b1111)]).is_empty());
        std::thread::spawn(|| keep_on_fast_cores("test")).join().unwrap();
    }
}
