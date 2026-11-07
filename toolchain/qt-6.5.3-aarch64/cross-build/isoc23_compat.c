/* C23 (glibc 2.38+) 符号兼容桩：目标 Pi 的 glibc 是 2.36，没有 __isoc23_*。
 * 这些符号是 glibc 2.39 头文件在 C++/C23 下把 strtol/sscanf 等重定向后的名字。
 * 这里映射回 2.36 的等价函数。不包含任何头文件，避免再次被重定向。 */
typedef struct _IO_FILE FILE;
extern long strtol(const char *, char **, int);
extern unsigned long strtoul(const char *, char **, int);
extern long long strtoll(const char *, char **, int);
extern unsigned long long strtoull(const char *, char **, int);
extern int vsscanf(const char *, const char *, __builtin_va_list);
extern int vfscanf(FILE *, const char *, __builtin_va_list);
extern int vscanf(const char *, __builtin_va_list);

long __isoc23_strtol(const char *n, char **e, int b) { return strtol(n, e, b); }
unsigned long __isoc23_strtoul(const char *n, char **e, int b) { return strtoul(n, e, b); }
long long __isoc23_strtoll(const char *n, char **e, int b) { return strtoll(n, e, b); }
unsigned long long __isoc23_strtoull(const char *n, char **e, int b) { return strtoull(n, e, b); }
int __isoc23_sscanf(const char *s, const char *f, ...) {
    __builtin_va_list ap; __builtin_va_start(ap, f); int r = vsscanf(s, f, ap); __builtin_va_end(ap); return r;
}
int __isoc23_fscanf(FILE *st, const char *f, ...) {
    __builtin_va_list ap; __builtin_va_start(ap, f); int r = vfscanf(st, f, ap); __builtin_va_end(ap); return r;
}
int __isoc23_scanf(const char *f, ...) {
    __builtin_va_list ap; __builtin_va_start(ap, f); int r = vscanf(f, ap); __builtin_va_end(ap); return r;
}
