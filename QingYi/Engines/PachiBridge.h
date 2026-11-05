//
//  PachiBridge.h
//  在 iOS 进程内运行 Pachi 围棋引擎的 C 接口.
//

#ifndef QY_PACHI_BRIDGE_H
#define QY_PACHI_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct QyPachiEngine QyPachiEngine;

/// 启动引擎; dataDir 为包含 patterns_mm.spat / patterns_mm.gamma 的目录.
/// secondsPerMove 为每手思考时间 (秒), 对应 Pachi 的 -t 参数.
/// 失败返回 NULL.
QyPachiEngine *qy_pachi_create(const char *dataDir, double secondsPerMove);

/// 发送一条 GTP 命令 (不含换行).
void qy_pachi_send(QyPachiEngine *engine, const char *line);

/// 读取一行 GTP 回复. 返回 1 成功, 0 超时, -1 引擎已结束.
int qy_pachi_read_line(QyPachiEngine *engine, char *out, int capacity, int timeoutMs);

/// 关闭引擎并等待后台线程退出.
void qy_pachi_destroy(QyPachiEngine *engine);

#ifdef __cplusplus
}
#endif

#endif
