import subprocess
import unittest
import tempfile
from pathlib import Path
from unittest.mock import Mock, patch

import service


class ServiceTests(unittest.TestCase):
    def test_update_stages_files_without_touching_launchd_or_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            root, runtime = home / "source", home / "runtime"
            plist = home / "Library/LaunchAgents" / f"{service.LABEL}.plist"
            plist.parent.mkdir(parents=True)
            plist.write_text("existing plist")
            runtime.mkdir()
            (runtime / "config.yaml").write_text("existing service config")
            root.mkdir()
            (root / "config.yaml").write_text("different checkout config")
            for name in ("scripts/service.py", ".build/release/coding-agent-proxy"):
                path = root / name
                path.parent.mkdir(parents=True)
                path.write_text("new executable")
                path.chmod(0o700)
            with patch.object(service, "ROOT", root), patch.object(service, "RUNTIME", runtime), \
                 patch.object(Path, "home", return_value=home), \
                 patch.object(service, "brew_paths"), patch.object(service.subprocess, "run") as run:
                self.assertEqual(service.manage("update"), 0)
                run.assert_not_called()
                self.assertEqual((runtime / "config.yaml").read_text(), "existing service config")
                self.assertEqual(plist.read_text(), "existing plist")
                self.assertEqual((runtime / ".build/release/coding-agent-proxy").read_text(), "new executable")
                with self.assertRaisesRegex(RuntimeError, "already installed"):
                    service.manage("install")
                run.assert_not_called()

    def test_occupied_port_waits_without_starting_or_stopping_processes(self):
        handlers = {}
        def register(number, handler):
            handlers[number] = handler
        def shutdown(_delay):
            handlers[service.signal.SIGTERM](None, None)
        with patch.object(service, "brew_paths", return_value=(Path("/brew/mihomo"), Path("/brew/etc/mihomo"))), \
             patch.object(Path, "is_file", return_value=True), \
             patch.object(service.os, "umask"), \
             patch.object(service.signal, "signal", side_effect=register), \
             patch.object(service.time, "sleep", side_effect=shutdown), \
             patch.object(service.subprocess, "check_output", return_value="7889\n"), \
             patch.object(service, "port_in_use", return_value=True), \
             patch.object(service.subprocess, "Popen") as popen:
            self.assertEqual(service.run_service(), 0)
            popen.assert_not_called()

    def test_running_brew_service_is_reused(self):
        for label in service.BREW_LABELS:
            with self.subTest(label=label):
                def launchctl(command, **kwargs):
                    running = command[-1].endswith("/" + label)
                    return subprocess.CompletedProcess(command, 0 if running else 1,
                                                       "\tstate = running\n" if running else "")
                with patch.object(service.subprocess, "run", side_effect=launchctl) as run:
                    self.assertTrue(service.mihomo_running(Path("/missing/mihomo")))
                    self.assertTrue(all(call.args[0][0] == "/bin/launchctl"
                                        for call in run.call_args_list))

    def test_loaded_but_stopped_service_is_not_running(self):
        with patch.object(service.subprocess, "run", return_value=
                          subprocess.CompletedProcess([], 0, "state = waiting\n")):
            self.assertFalse(service.mihomo_running(Path("/missing/mihomo")))

    def test_manual_binary_is_reused(self):
        def run(command, **kwargs):
            return subprocess.CompletedProcess(command, 0,
                "/opt/homebrew/opt/mihomo/bin/mihomo -d /opt/homebrew/etc/mihomo\n" if command[0] == "/bin/ps" else "")
        with patch.object(service.subprocess, "run", side_effect=run):
            self.assertTrue(service.mihomo_running(Path("/opt/homebrew/opt/mihomo/bin/mihomo")))

    def test_supervisor_starts_only_missing_mihomo_and_cleans_up(self):
        for already_running in (True, False):
            with self.subTest(already_running=already_running):
                mihomo = Mock()
                mihomo.poll.return_value = None
                proxy = Mock(pid=123, returncode=1)
                proxy.poll.return_value = 1
                spawned = [proxy] if already_running else [mihomo, proxy]
                with patch.object(service, "brew_paths", return_value=(Path("/brew/mihomo"), Path("/brew/etc/mihomo"))), \
                     patch.object(service, "mihomo_running", return_value=already_running), \
                     patch.object(Path, "is_file", return_value=True), \
                     patch.object(service.os, "umask"), \
                     patch.object(service.subprocess, "check_output", return_value="7889\n"), \
                     patch.object(service, "port_in_use", return_value=False), \
                     patch.object(service.signal, "signal"), \
                     patch.object(service.time, "sleep"), \
                     patch.object(service.subprocess, "Popen", side_effect=spawned) as popen:
                    with self.assertRaisesRegex(RuntimeError, "Managed process"):
                        service.run_service()
                    self.assertEqual(popen.call_count, len(spawned))
                    if not already_running:
                        self.assertEqual(popen.call_args_list[0].args[0],
                                         ["/brew/mihomo", "-d", "/brew/etc/mihomo"])
                        mihomo.terminate.assert_called_once()
                    else:
                        mihomo.terminate.assert_not_called()


if __name__ == "__main__":
    unittest.main()
