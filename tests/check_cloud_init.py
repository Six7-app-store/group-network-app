"""Exercise IPv4, IPv6 and dual-stack cloud-init with synthetic data only."""
import json
import pathlib
import subprocess
import sys
import types
from unittest.mock import patch

root = pathlib.Path(__file__).resolve().parents[1]
tofu = sys.argv[1] if len(sys.argv) > 1 else "tofu"

class FakePath:
    def __init__(self, name):
        self.name = str(name)

    def glob(self, pattern):
        return [FakePath("/sys/class/net/ens4/address"), FakePath("/sys/class/net/ens5/address")]

    @property
    def parent(self):
        return types.SimpleNamespace(name="ens4" if "ens4" in self.name else "ens5")

    def read_text(self):
        if self.name.endswith("address"):
            return "fa:16:3e:00:00:01\n" if "ens4" in self.name else "fa:16:3e:00:00:03\n"
        return json.dumps(netplan)

    def write_text(self, text):
        written[self.name] = json.loads(text)

    def chmod(self, mode):
        assert mode == 0o600

for mode in ["ipv4", "ipv6", "dual"]:
    addresses = (["10.77.0.11/24"] if mode != "ipv6" else []) + (["fd77:77::b/64"] if mode != "ipv4" else [])
    args = dict(
        lab_mac="fa:16:3e:00:00:01", lab_addresses=addresses,
        secondary_mac="fa:16:3e:00:00:03" if mode == "dual" else "",
        secondary_address="198.51.100.10/24", secondary_cidr="198.51.100.0/24",
        secondary_gateway="198.51.100.1",
        team_users=[dict(username="ualice", password="SyntheticPassword123"), dict(username="ubob", password="SyntheticPassword456")],
    )
    expression = 'jsonencode(yamldecode(templatefile("user-data.yaml.tpl", jsondecode(' + json.dumps(json.dumps(args)) + '))))'
    result = subprocess.run(
        [tofu, f"-chdir={root / 'tofu'}", "console"], input=expression + "\n",
        text=True, capture_output=True, check=True, timeout=30,
    )
    config = json.loads(json.loads(result.stdout.strip()))
    assert config["ssh_pwauth"] is True and config["disable_root"] is True
    assert "openssh-server" in config["packages"] and "iputils-ping" in config["packages"]
    assert [u["name"] for u in config["users"]] == ["ualice", "ubob"]
    assert all("sudo" not in u for u in config["users"])
    assert len(config["chpasswd"]["users"]) == 2 and config["chpasswd"]["expire"] is False
    assert ["chmod", "0700", "/home/ualice"] in config["runcmd"]
    assert ["chmod", "0700", "/home/ubob"] in config["runcmd"]
    script = next(f for f in config["write_files"] if f["path"].endswith("configure-group-lab.py"))
    assert config["runcmd"][0] == ["python3", script["path"]]
    ssh = next(f for f in config["write_files"] if "sshd_config.d" in f["path"])
    assert "PasswordAuthentication yes" in ssh["content"] and "PermitRootLogin no" in ssh["content"]
    written = {}
    netplan = {"network": {"ethernets": {
        "access": {"match": {"macaddress": "fa:16:3e:00:00:02"}, "dhcp4": True},
        "generated-lab": {"match": {"macaddress": "fa:16:3e:00:00:01"}, "dhcp4": True},
    }}}
    fake_yaml = types.SimpleNamespace(safe_load=json.loads, safe_dump=json.dumps)
    with patch.dict(sys.modules, {"yaml": fake_yaml}), patch("pathlib.Path", FakePath), patch("glob.glob", return_value=["/etc/netplan/50-cloud-init.yaml"]):
        exec(compile(script["content"], script["path"], "exec"), {})
    ethernets = written["/etc/netplan/99-group-lab.yaml"]["network"]["ethernets"]
    assert ethernets["generated-lab"]["addresses"] == addresses
    assert not ethernets["generated-lab"]["dhcp4"] and not ethernets["generated-lab"]["accept-ra"]
    assert "routes" not in ethernets["generated-lab"]
    assert netplan["network"]["ethernets"]["access"]["dhcp4"] is True
    if mode == "dual":
        secondary = ethernets["ens5"]
        assert secondary["addresses"] == ["198.51.100.10/24"]
        assert secondary["routing-policy"] == [{"from": "198.51.100.10/32", "table": 100, "priority": 100}]
        assert all(route["table"] == 100 for route in secondary["routes"])
        assert secondary["routes"][1] == {"to": "0.0.0.0/0", "via": "198.51.100.1", "table": 100}
    else:
        assert set(ethernets) == {"generated-lab"}
    # Missing hotplug NIC must stop after the finite retry budget.
    with patch.dict(sys.modules, {"yaml": fake_yaml}), patch("pathlib.Path", FakePath), patch("glob.glob", return_value=[]), patch("time.sleep") as sleep:
        namespace = {}
        exec(compile(script["content"], script["path"], "exec"), namespace)
        try:
            namespace["interface_id"]("fa:16:3e:ff:ff:ff")
            raise AssertionError("Missing interface unexpectedly succeeded")
        except RuntimeError:
            assert sleep.call_count == 60
    print(f"Cloud-init {mode}: accounts, lab addressing, routing and bounded NIC wait passed")
