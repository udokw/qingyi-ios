//
//  PikafishBridge.cpp
//  把 Pikafish 的 UCI 主循环放进进程内后台线程, 用内存流替代 stdio 管道.
//  iOS 不允许 fork/exec 子进程, 因此引擎必须静态链接后在本进程运行.
//

#include "PikafishBridge.h"

#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <iostream>
#include <mutex>
#include <streambuf>
#include <string>
#include <thread>
#include <vector>

#include "attacks.h"
#include "misc.h"
#include "position.h"
#include "tune.h"
#include "uci.h"

namespace {

/// 引擎输入: 阻塞式字符队列, 供 std::getline(std::cin, ...) 读取
class EngineInput : public std::streambuf {
   public:
    void push(const char* line) {
        std::lock_guard<std::mutex> lock(mutex_);
        for (const char* p = line; *p != '\0'; ++p) {
            queue_.push_back(*p);
        }
        queue_.push_back('\n');
        cond_.notify_all();
    }

    void close() {
        std::lock_guard<std::mutex> lock(mutex_);
        closed_ = true;
        cond_.notify_all();
    }

   protected:
    int_type underflow() override {
        std::unique_lock<std::mutex> lock(mutex_);
        cond_.wait(lock, [this] { return !queue_.empty() || closed_; });
        if (queue_.empty()) return traits_type::eof();
        return traits_type::to_int_type(queue_.front());
    }

    int_type uflow() override {
        std::unique_lock<std::mutex> lock(mutex_);
        cond_.wait(lock, [this] { return !queue_.empty() || closed_; });
        if (queue_.empty()) return traits_type::eof();
        const char c = queue_.front();
        queue_.pop_front();
        return traits_type::to_int_type(c);
    }

    std::streamsize xsgetn(char* out, std::streamsize count) override {
        std::unique_lock<std::mutex> lock(mutex_);
        cond_.wait(lock, [this] { return !queue_.empty() || closed_; });
        std::streamsize i = 0;
        while (i < count && !queue_.empty()) {
            out[i++] = queue_.front();
            queue_.pop_front();
        }
        return i;
    }

   private:
    std::mutex              mutex_;
    std::condition_variable cond_;
    std::deque<char>        queue_;
    bool                    closed_ = false;
};

/// 引擎输出: 按行切分, Swift 侧阻塞读取
class EngineOutput : public std::streambuf {
   public:
    int_type overflow(int_type c) override {
        if (traits_type::eq_int_type(c, traits_type::eof())) return c;
        const char ch = traits_type::to_char_type(c);
        append(&ch, 1);
        return c;
    }

    std::streamsize xsputn(const char* data, std::streamsize count) override {
        append(data, static_cast<size_t>(count));
        return count;
    }

    bool readLine(std::string& out, int timeoutMs) {
        std::unique_lock<std::mutex> lock(mutex_);
        if (lines_.empty()) {
            if (!cond_.wait_for(lock, std::chrono::milliseconds(timeoutMs),
                                [this] { return !lines_.empty() || closed_; })) {
                return false;
            }
        }
        if (lines_.empty()) return false;
        out = std::move(lines_.front());
        lines_.pop_front();
        return true;
    }

    void close() {
        std::lock_guard<std::mutex> lock(mutex_);
        closed_ = true;
        cond_.notify_all();
    }

   private:
    void append(const char* data, size_t count) {
        std::lock_guard<std::mutex> lock(mutex_);
        pending_.append(data, count);
        size_t pos;
        while ((pos = pending_.find('\n')) != std::string::npos) {
            lines_.push_back(pending_.substr(0, pos));
            pending_.erase(0, pos + 1);
        }
        // 单行异常长时也要放行, 防止缓冲无限增长
        if (pending_.size() > (1u << 20)) {
            lines_.push_back(pending_);
            pending_.clear();
        }
        cond_.notify_all();
    }

    std::mutex              mutex_;
    std::condition_variable cond_;
    std::string             pending_;
    std::deque<std::string> lines_;
    bool                    closed_ = false;
};

EngineInput*  g_input  = nullptr;
EngineOutput* g_output = nullptr;

}  // namespace

struct QyEngine {
    std::string nnuePath;
    std::thread worker;
};

QyEngine* qy_engine_create(const char* nnuePath) {
    if (g_input != nullptr || g_output != nullptr) {
        return nullptr;  // 只支持单实例
    }

    auto* engine    = new QyEngine();
    engine->nnuePath = nnuePath ? nnuePath : "";

    g_input  = new EngineInput();
    g_output = new EngineOutput();

    std::cin.rdbuf(g_input);
    std::cout.rdbuf(g_output);

    engine->worker = std::thread([engine]() {
        // 用 nnue 文件路径作为 argv[0], 引擎会以它的父目录作为资源目录,
        // 启动时自动加载同目录下的 pikafish.nnue
        std::vector<char> arg0(engine->nnuePath.begin(), engine->nnuePath.end());
        arg0.push_back('\0');
        char* argv[] = {arg0.data(), nullptr};

        Stockfish::CommandLine cli(1, argv);

        Stockfish::Attacks::init();
        Stockfish::Position::init();

        Stockfish::UCIEngine uci(std::move(cli));
        Stockfish::Tune::init(uci.engine_options());
        uci.loop();
    });

    return engine;
}

void qy_engine_send(QyEngine* engine, const char* line) {
    (void)engine;
    if (g_input == nullptr || line == nullptr) return;
    g_input->push(line);
}

int qy_engine_read_line(QyEngine* engine, char* out, int capacity, int timeoutMs) {
    (void)engine;
    if (g_output == nullptr || out == nullptr || capacity <= 0) return -1;

    std::string line;
    if (!g_output->readLine(line, timeoutMs)) return 0;

    const int length = static_cast<int>(line.size());
    const int copy   = length < capacity - 1 ? length : capacity - 1;
    std::memcpy(out, line.data(), static_cast<size_t>(copy));
    out[copy] = '\0';
    return 1;
}

void qy_engine_destroy(QyEngine* engine) {
    if (engine == nullptr) return;

    if (g_input != nullptr) g_input->push("quit");
    if (engine->worker.joinable()) engine->worker.join();

    if (g_output != nullptr) g_output->close();
    if (g_input != nullptr) g_input->close();

    delete engine;
}
