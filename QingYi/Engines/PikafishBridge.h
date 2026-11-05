//
//  PikafishBridge.h
//  Pikafish 引擎的 C 桥接层 (iOS 进程内运行, 不使用子进程)
//

#ifndef PIKAFISH_BRIDGE_H
#define PIKAFISH_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/// 引擎句柄 (不透明)
typedef struct QyEngine QyEngine;

/// 创建引擎并在后台线程启动 UCI 循环.
/// nnuePath: "pikafish.nnue" 的完整路径; 同时用作引擎的二进制目录,
///           引擎启动时会自动从该目录加载默认网络.
QyEngine *qy_engine_create(const char *nnuePath);

/// 发送一行 UCI 命令 (自动补换行)
void qy_engine_send(QyEngine *engine, const char *line);

/// 阻塞读取一行引擎输出.
/// 返回 1 = 读到一行, 0 = 超时, -1 = 引擎已关闭
int qy_engine_read_line(QyEngine *engine, char *out, int capacity, int timeoutMs);

/// 发送 quit 并等待引擎线程退出
void qy_engine_destroy(QyEngine *engine);

#ifdef __cplusplus
}
#endif

#endif /* PIKAFISH_BRIDGE_H */
