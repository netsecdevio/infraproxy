"""Exercise actual macOS sandbox denials with disposable fixtures."""
import os, pathlib, subprocess, tempfile, socket
root = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="infravibe-sandbox-") as tmp:
    base = pathlib.Path(tmp).resolve()
    workspace = base / "workspace"; workspace.mkdir()
    home = base / "home"; home.mkdir()
    secret = base / "outside"; secret.write_text("fixture-secret")
    (workspace / "escape").symlink_to(secret)
    def run(command):
        return subprocess.run(["/usr/bin/sandbox-exec", "-f", str(root / "Resources/terminal.sb"), "-D", "WORKSPACE="+str(workspace), "-D", "SESSION_HOME="+str(home), "/bin/sh", "-c", command], cwd=workspace, env={"PATH":"/usr/bin:/bin", "HOME":str(home)}, capture_output=True)
    assert run("echo yes > allowed; cat allowed").returncode == 0
    listener = socket.socket(); listener.bind(("127.0.0.1", 0)); listener.listen()
    port = listener.getsockname()[1]
    for name, command in {
        "outside read": f"cat '{secret}'",
        "outside write": f"echo bad > '{secret}'",
        "symlink escape": "cat escape",
        "data volume alias": f"cat /System/Volumes/Data{secret}",
        "network": f"/usr/bin/curl --max-time 2 http://127.0.0.1:{port}/",
        "keychain": "/usr/bin/security list-keychains",
    }.items():
        result = run(command)
        assert result.returncode != 0, name + " unexpectedly allowed"
        if name == "network":
            listener.settimeout(.1)
            try:
                connection, _ = listener.accept(); connection.close(); raise AssertionError("network connected")
            except socket.timeout: pass
        assert b"fixture-secret" not in result.stdout, name + " leaked contents"
    assert secret.read_text() == "fixture-secret"
print("PASS: workspace writes; outside read/write, symlink escape, network and Keychain denied")
