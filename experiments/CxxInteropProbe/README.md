# Swift/C++ interop probe

一次性实验：Swift 6.4 直接（`-cxx-interoperability-mode=default`）导入 libgdp 的头文件能走多远。结论和逐项结果见 [docs/prototype-findings.md](../../docs/prototype-findings.md) 的风险 1。

先运行 `scripts/build-gdpcore.sh macos`，然后：

```bash
swift run --package-path experiments/CxxInteropProbe Probe
```

`Sources/Probe/main.swift` 里注释掉的几段是编译不过（或让编译器崩溃）的写法，保留下来作为记录。
