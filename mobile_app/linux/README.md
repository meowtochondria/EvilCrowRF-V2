## Ubuntu dependencies
### Clang 22 PPA
`/etc/apt/sources.list.d/clang-22.sources`:
```
Types: deb
URIs: http://apt.llvm.org/noble
Suites: llvm-toolchain-noble-22
Components: main
Signed-By: /etc/apt/trusted.gpg.d/apt.llvm.org.asc
```
TODO: Add how to import key
### Install dependencies
```
sudo aptitude install libgtk-3-dev cmake ninja-build clang-22
```
Set `clang++-22` to provide `clang++`, and `clang-22` to provide `clang`:
```
sudo update-alternatives --install /usr/bin/clang++ clang++ $(which clang++-22) 0
sudo update-alternatives --install /usr/bin/clang clang $(which clang-22) 0
```
