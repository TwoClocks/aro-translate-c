# aro-translate-c
Use AroCC to translate C to Zig

Just scaffolding at the moment. Currently only simple var decls, `#Define` and `typedef`s work

```c
int var1=7;
#define __UQUAD_TYPE		unsigned long int

#define __SYSCALL_ULONG_TYPE	__UQUAD_TYPE
#define __CPU_MASK_TYPE 	__SYSCALL_ULONG_TYPE
/* Type for array elements in 'cpu_set_t'.  */
typedef __CPU_MASK_TYPE __cpu_mask;
```
to 

```rust
pub var var1: c_int = 7;
pub const __cpu_mask = c_ulong;
```

the `build.zig` assumes [arocc](https://github.com/Vexu/arocc) is in the relative directly of `../arocc`.

Both arocc and zig should be from head of master.


