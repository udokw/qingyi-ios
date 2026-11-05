//
//  KataGoBridge.h
//  KataGo 围棋引擎的 C 桥接层 (iOS 进程内运行)
//

#ifndef KATAGO_BRIDGE_H
#define KATAGO_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct QyGoEngine QyGoEngine;

/// modelPath: 神经网络文件; configPath: gtp 配置文件
QyGoEngine *qy_katago_create(const char *modelPath, const char *configPath);

void qy_katago_send(QyGoEngine *engine, const char *line);

/// 返回 1 = 读到一行, 0 = 超时, -1 = 已关闭
int qy_katago_read_line(QyGoEngine *engine, char *out, int capacity, int timeoutMs);

void qy_katago_destroy(QyGoEngine *engine);

#ifdef __cplusplus
}
#endif

#endif /* KATAGO_BRIDGE_H */
