//
//  qy_pachi_io.h
//  Pachi 在 iOS 进程内运行时的 GTP 输入/输出重定向.
//
//  只被 pachi.c 与 gtp.c 包含 (放在它们的 #include 列表最后),
//  这样仅替换 GTP 主循环和 GTP 回复的 stdio 调用,
//  不会影响其它源文件里的调试输出.
//

#ifndef QY_PACHI_IO_H
#define QY_PACHI_IO_H

#include <stdarg.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 由 PachiBridge.cpp 实现 */
int qy_pachi_io_getline(char *buf, int size);
int qy_pachi_io_write(const char *data, int len);
int qy_pachi_io_printf(const char *fmt, ...);
int qy_pachi_io_vprintf(const char *fmt, va_list ap);
int qy_pachi_io_putchar(int c);
int qy_pachi_io_fputs(const char *str);
int qy_pachi_io_fprintf(FILE *stream, const char *fmt, ...);
int qy_pachi_io_fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream);
int qy_pachi_io_fflush(FILE *stream);

#ifdef __cplusplus
}
#endif

/* 仅在本编译单元内生效的替换宏 (桥接实现文件会定义 QY_PACHI_NO_REMAP) */
#ifndef QY_PACHI_NO_REMAP
#define fgets(buf, size, stream)     qy_pachi_io_getline((buf), (size))
#define printf(...)                  qy_pachi_io_printf(__VA_ARGS__)
#define vprintf(fmt, ap)             qy_pachi_io_vprintf((fmt), (ap))
#define putchar(c)                   qy_pachi_io_putchar((c))
#define fputs(str, stream)           qy_pachi_io_fputs((str))
#define fprintf(stream, ...)         qy_pachi_io_fprintf((stream), __VA_ARGS__)
#define fwrite(ptr, size, n, stream) qy_pachi_io_fwrite((ptr), (size), (n), (stream))
#define fflush(stream)               qy_pachi_io_fflush((stream))
#endif

#endif /* QY_PACHI_IO_H */
