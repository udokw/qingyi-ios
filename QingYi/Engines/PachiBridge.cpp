//
//  PachiBridge.cpp
//  把 Pachi 的 GTP 主循环嵌进 iOS 进程:
//  - pachi.c 的 main() 已重命名为 qy_pachi_main(), 在后台线程运行;
//  - pachi.c / gtp.c 里的 stdin/stdout 调用被 qy_pachi_io.h 重定向到内存队列.
//

#define QY_PACHI_NO_REMAP 1
#include "qy_pachi_io.h"

#include "PachiBridge.h"

#include <algorithm>
#include <chrono>
#include <climits>
#include <condition_variable>
#include <csetjmp>
#include <setjmp.h>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

extern "C" int qy_pachi_main(int argc, char *argv[]);

struct QyPachiEngine {
    std::mutex mutex;
    std::condition_variable cond;
    std::deque<std::string> input;
    std::deque<std::string> output;
    std::string partial;
    bool inputClosed = false;
    bool closed = false;
    std::thread worker;
};

namespace {
QyPachiEngine *g_engine = nullptr;

// Pachi 在致命错误时会调用 exit(); 用 longjmp 把它挡在引擎线程里.
sigjmp_buf g_jump;
volatile bool g_jumpReady = false;

void runPachiMain(int argc, char **argv) {
    if (sigsetjmp(g_jump, 1) == 0) {
        g_jumpReady = true;
        qy_pachi_main(argc, argv);
        g_jumpReady = false;
    } else {
        g_jumpReady = false;
    }
}
}

namespace {

void appendOutput(const char *data, int len) {
    QyPachiEngine *e = g_engine;
    if (e == nullptr || data == nullptr || len <= 0) {
        return;
    }
    std::lock_guard<std::mutex> lock(e->mutex);
    e->partial.append(data, static_cast<size_t>(len));
    for (;;) {
        const size_t pos = e->partial.find('\n');
        if (pos == std::string::npos) {
            break;
        }
        std::string line = e->partial.substr(0, pos);
        e->partial.erase(0, pos + 1);
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        e->output.push_back(std::move(line));
    }
    e->cond.notify_all();
}

int writeFormatted(const char *fmt, va_list ap) {
    char stackBuffer[1024];
    va_list copy;
    va_copy(copy, ap);
    const int n = vsnprintf(stackBuffer, sizeof(stackBuffer), fmt, copy);
    va_end(copy);
    if (n < 0) {
        return n;
    }
    if (static_cast<size_t>(n) < sizeof(stackBuffer)) {
        appendOutput(stackBuffer, n);
    } else {
        std::string big(static_cast<size_t>(n) + 1, '\0');
        va_list copy2;
        va_copy(copy2, ap);
        vsnprintf(&big[0], big.size(), fmt, copy2);
        va_end(copy2);
        appendOutput(big.data(), n);
    }
    return n;
}

} // namespace

extern "C" int qy_pachi_io_write(const char *data, int len) {
    appendOutput(data, len);
    return len;
}

extern "C" int qy_pachi_io_printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    const int n = writeFormatted(fmt, ap);
    va_end(ap);
    return n;
}

extern "C" int qy_pachi_io_vprintf(const char *fmt, va_list ap) {
    return writeFormatted(fmt, ap);
}

extern "C" int qy_pachi_io_putchar(int c) {
    const char ch = static_cast<char>(c);
    appendOutput(&ch, 1);
    return c;
}

extern "C" int qy_pachi_io_fputs(const char *str, FILE *stream) {
    if (str != nullptr && stream != nullptr && stream != stdout) {
        return fputs(str, stream);
    }
    if (str != nullptr) {
        appendOutput(str, static_cast<int>(strlen(str)));
    }
    return 1;
}

extern "C" int qy_pachi_io_fprintf(FILE *stream, const char *fmt, ...) {
    if (stream != nullptr && stream != stdout) {
        va_list ap;
        va_start(ap, fmt);
        const int n = vfprintf(stream, fmt, ap);
        va_end(ap);
        return n;
    }
    va_list ap;
    va_start(ap, fmt);
    const int n = writeFormatted(fmt, ap);
    va_end(ap);
    return n;
}

extern "C" int qy_pachi_io_fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream) {
    if (stream != nullptr && stream != stdout) {
        return static_cast<int>(fwrite(ptr, size, nmemb, stream));
    }
    if (ptr != nullptr && size > 0 && nmemb > 0) {
        const size_t total = size * nmemb;
        if (total <= static_cast<size_t>(INT_MAX)) {
            appendOutput(static_cast<const char *>(ptr), static_cast<int>(total));
        }
    }
    return static_cast<int>(nmemb);
}

extern "C" int qy_pachi_io_fflush(FILE *stream) {
    if (stream != nullptr && stream != stdout) {
        return fflush(stream);
    }
    return 0;
}

extern "C" void qy_pachi_io_exit(int code) {
    if (g_jumpReady) {
        g_jumpReady = false;
        siglongjmp(g_jump, code != 0 ? code : 1);
    }
    _exit(code);
}

extern "C" int qy_pachi_io_getline(char *buf, int size) {
    QyPachiEngine *e = g_engine;
    if (e == nullptr || buf == nullptr || size <= 1) {
        return 0;
    }
    std::unique_lock<std::mutex> lock(e->mutex);
    e->cond.wait(lock, [e] { return !e->input.empty() || e->inputClosed; });
    if (e->input.empty()) {
        return 0; // EOF: 让 Pachi 主循环正常退出
    }
    std::string line = std::move(e->input.front());
    e->input.pop_front();
    if (!line.empty() && line.back() == '\n') {
        line.pop_back();
    }
    if (!line.empty() && line.back() == '\r') {
        line.pop_back();
    }
    int n = static_cast<int>(line.size());
    if (n > size - 2) {
        n = size - 2;
    }
    if (n > 0) {
        memcpy(buf, line.data(), static_cast<size_t>(n));
    }
    buf[n++] = '\n';
    buf[n] = '\0';
    return 1;
}

extern "C" QyPachiEngine *qy_pachi_create(const char *dataDir, double secondsPerMove) {
    if (g_engine != nullptr || dataDir == nullptr) {
        return nullptr;
    }

    const std::string dir(dataDir);
    const std::string spat = dir + "/patterns_mm.spat";
    const std::string gamma = dir + "/patterns_mm.gamma";

    // Pachi 找不到 pattern 数据会调用 die() 直接退出进程, 这里先确认资源存在.
    FILE *probe = fopen(spat.c_str(), "rb");
    if (probe == nullptr) {
        return nullptr;
    }
    fclose(probe);
    probe = fopen(gamma.c_str(), "rb");
    if (probe == nullptr) {
        return nullptr;
    }
    fclose(probe);

    // Pachi 的 get_data_file() 会优先读 DATA_DIR.
    setenv("DATA_DIR", dir.c_str(), 1);

    char timeBuffer[32];
    const double seconds = secondsPerMove > 0.05 ? secondsPerMove : 0.5;
    snprintf(timeBuffer, sizeof(timeBuffer), "%.2f", seconds);

    std::vector<std::string> args;
    args.push_back(dir + "/pachi");
    args.push_back("-t");
    args.push_back(timeBuffer);
    args.push_back("-d");
    args.push_back("0");
    // 不加载 joseki 库: 定式文件没打进包, 缺失时 Pachi 会直接 die().
    // 1-6 级用不到定式, 关掉更稳.
    args.push_back("--nojoseki");

    QyPachiEngine *e = new QyPachiEngine();
    g_engine = e;

    e->worker = std::thread([e, args]() {
        std::vector<char *> cargs;
        cargs.reserve(args.size() + 1);
        for (const std::string &s : args) {
            cargs.push_back(const_cast<char *>(s.c_str()));
        }
        cargs.push_back(nullptr);
        runPachiMain(static_cast<int>(args.size()), cargs.data());

        std::lock_guard<std::mutex> lock(e->mutex);
        e->closed = true;
        e->cond.notify_all();
    });

    return e;
}

extern "C" void qy_pachi_send(QyPachiEngine *engine, const char *line) {
    if (engine == nullptr || line == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(engine->mutex);
    if (engine->inputClosed || engine->closed) {
        return;
    }
    engine->input.emplace_back(line);
    engine->cond.notify_all();
}

extern "C" int qy_pachi_read_line(QyPachiEngine *engine, char *out, int capacity, int timeoutMs) {
    if (engine == nullptr || out == nullptr || capacity <= 0) {
        return -1;
    }
    std::unique_lock<std::mutex> lock(engine->mutex);
    const bool ready = engine->cond.wait_for(
        lock,
        std::chrono::milliseconds(timeoutMs > 0 ? timeoutMs : 1),
        [engine] { return !engine->output.empty() || engine->closed; });
    if (!ready) {
        return 0;
    }
    if (engine->output.empty()) {
        return -1;
    }
    std::string line = std::move(engine->output.front());
    engine->output.pop_front();
    const int n = std::min(static_cast<int>(line.size()), capacity - 1);
    if (n > 0) {
        memcpy(out, line.data(), static_cast<size_t>(n));
    }
    out[n] = '\0';
    return 1;
}

extern "C" void qy_pachi_destroy(QyPachiEngine *engine) {
    if (engine == nullptr) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(engine->mutex);
        engine->inputClosed = true;
        engine->cond.notify_all();
    }
    if (engine->worker.joinable()) {
        engine->worker.join();
    }
    if (g_engine == engine) {
        g_engine = nullptr;
    }
    delete engine;
}
