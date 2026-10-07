import Testing
@testable import CallrecCore

// Regression: install-agent wrote a non-existent binary path, launchd crash-looped
// with EX_CONFIG, and `status` still said "Watching" from a stale state file.
@Test func launchdRunningJobParsesAsRunning() {
    let out = """
    gui/501/com.blaxify.callrec = {
    \tactive count = 1
    \tstate = running
    \tpid = 4242
    }
    """
    #expect(LaunchdJob.parse(out) == .init(running: true, detail: "state running"))
}

@Test func launchdCrashLoopingJobIsNotRunning() {
    let out = """
    gui/501/com.blaxify.callrec = {
    \tstate = spawn scheduled
    \tlast exit code = 78: EX_CONFIG
    }
    """
    let st = LaunchdJob.parse(out)
    #expect(st.running == false)
    #expect(st.detail == "state spawn scheduled, last exit 78: EX_CONFIG")
}

@Test func launchdNestedStateLinesDoNotFoolTheParser() {
    // `launchctl print` also has an indented "state = active" inside sub-blocks;
    // the first top-level "state =" line is the job's.
    let out = "\tstate = running\n\t\tstate = active\n"
    #expect(LaunchdJob.parse(out).running == true)
}
