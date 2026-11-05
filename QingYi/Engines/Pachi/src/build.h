#ifndef PACHI_BUILD_H
#define PACHI_BUILD_H

/* 静态库编译时无需 Makefile 生成, 这里给出固定值供 version.h 使用 */
#define PACHI_GIT_BRANCH   "ios"
#define PACHI_GIT_HASH     "qingyi"
#define PACHI_BUILD_DATE   __DATE__
#define PACHI_BUILD_TARGET "ios-arm64"
#define PACHI_CFLAGS       ""
#define PACHI_COMPILER     "clang"
#define PACHI_CC1          ""

#endif
