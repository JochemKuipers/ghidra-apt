# Ghidra APT package

Unofficial Debian package of [Ghidra](https://github.com/NationalSecurityAgency/ghidra),
repacked from the official PUBLIC release zip as `ghidra`.

Install from the combined APT repo:

```sh
curl -fsSL https://jochemkuipers.github.io/apt-repo/jochem.sources \
  | sudo tee /etc/apt/sources.list.d/jochem.sources
sudo apt update
sudo apt install ghidra
```

Requires a Java 21 JDK/JRE (`openjdk-21-jdk` or `openjdk-21-jre`).

This repo watches [NationalSecurityAgency/ghidra releases](https://github.com/NationalSecurityAgency/ghidra/releases),
verifies SHA-256, installs under `/opt/ghidra`, and publishes GitHub Releases consumed by
[apt-repo](https://github.com/JochemKuipers/apt-repo).
