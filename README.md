# aro-translate-c
Use AroCC to translate C to Zig

Just scafolding at the moment. But will transalte

```c
int var1=7;
```
to 

```zig
var var1: c_int = 7;
```

the `build.zig` assumes [arocc](https://github.com/Vexu/arocc) is in the relative directly of `../arocc`.

Both arocc and zig should be from head of master.


