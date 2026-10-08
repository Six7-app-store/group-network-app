"""Render synthetic cloud-init through OpenTofu, without contacting OpenStack."""
import json
import pathlib
import subprocess
import sys
import types
from unittest.mock import patch

root = pathlib.Path(__file__).resolve().parents[1]
tofu = sys.argv[1] if len(sys.argv) > 1 else "tofu"
expression = 'jsonencode(yamldecode(templatefile("user-data.yaml.tpl", {lab_mac="fa:16:3e:00:00:01", lab_ip="10.77.0.11", team_users=[{username="ualice", password="SyntheticPassword123"}, {username="ubob", password="SyntheticPassword456"}]})))'
result = subprocess.run(
    [tofu, f"-chdir={root / 'terraform'}", "console"],
    input=expression + "\n", text=True, capture_output=True, check=True,
)
config = json.loads(json.loads(result.stdout.strip()))
assert config["ssh_pwauth"] is True
assert config["disable_root"] is True
assert [u["name"] for u in config["users"]] == ["ualice", "ubob"]
assert all("sudo" not in u for u in config["users"])
assert len(config["chpasswd"]["users"]) == 2
assert config["chpasswd"]["expire"] is False
assert ["chmod", "0700", "/home/ualice"] in config["runcmd"]
assert ["chmod", "0700", "/home/ubob"] in config["runcmd"]
script = next(f for f in config["write_files"] if f["path"].endswith("configure-group-lab.py"))
compile(script["content"], script["path"], "exec")
assert config["runcmd"][0] == ["python3", script["path"]]
ssh_config = next(f for f in config["write_files"] if "sshd_config.d" in f["path"])
assert "PasswordAuthentication yes" in ssh_config["content"]
assert "PermitRootLogin no" in ssh_config["content"]

# Exercise the generated guest script against synthetic netplan files.
# YAML's API is stubbed with JSON here; the real YAML rendering was checked above.
written = {}
netplan = {"network": {"ethernets": {
    "access": {"match": {"macaddress": "fa:16:3e:00:00:02"}, "dhcp4": True},
    "generated-lab": {"match": {"macaddress": "fa:16:3e:00:00:01"}, "dhcp4": True},
}}}

class FakePath:
    def __init__(self, name):
        self.name = str(name)

    def glob(self, pattern):
        return [FakePath("/sys/class/net/ens4/address")]

    @property
    def parent(self):
        return types.SimpleNamespace(name="ens4")

    def read_text(self):
        return "fa:16:3e:00:00:01\n" if self.name.endswith("address") else json.dumps(netplan)

    def write_text(self, text):
        written[self.name] = json.loads(text)

    def chmod(self, mode):
        assert mode == 0o600

fake_yaml = types.SimpleNamespace(safe_load=json.loads, safe_dump=json.dumps)
with patch.dict(sys.modules, {"yaml": fake_yaml}), patch("pathlib.Path", FakePath), patch("glob.glob", return_value=["/etc/netplan/50-cloud-init.yaml"]):
    exec(compile(script["content"], script["path"], "exec"), {})
override = written["/etc/netplan/99-group-lab.yaml"]["network"]["ethernets"]
assert set(override) == {"generated-lab"}
assert override["generated-lab"]["addresses"] == ["10.77.0.11/24"]
assert override["generated-lab"]["dhcp4"] is False
assert override["generated-lab"]["accept-ra"] is False
assert netplan["network"]["ethernets"]["access"]["dhcp4"] is True
print("Cloud-init accounts, SSH configuration and generated lab NIC script: passed")
