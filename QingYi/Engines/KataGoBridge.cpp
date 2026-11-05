//
//  KataGoBridge.cpp
//  把 KataGo 的 GTP 主循环放进进程内后台线程, 用内存流替代 stdio.
//

#include "KataGoBridge.h"

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

#include "main.h"

// main.cpp 不参与编译 (它自带 main), 这里补上 GTP 需要的版本信息实现
namespace Version {
std::string getKataGoVersion() { return "1.16.0-ios"; }
std::string getKataGoVersionForHelp() { return "KataGo v1.16.0 (iOS, Eigen CPU)"; }
std::string getKataGoVersionFullInfo() { return getKataGoVersionForHelp(); }
std::string getGitRevision() { return "ios"; }
std::string getGitRevisionWithBackend() { return "ios/eigen"; }
}  // namespace Version

namespace {

class GoInput : public std::streambuf {
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

class GoOutput : public std::streambuf {
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

GoInput*  g_input  = nullptr;
GoOutput* g_output = nullptr;

}  // namespace

struct QyGoEngine {
    std::string modelPath;
    std::string configPath;
    std::thread worker;
};

QyGoEngine* qy_katago_create(const char* modelPath, const char* configPath) {
    if (g_input != nullptr || g_output != nullptr) {
        return nullptr;
    }

    auto* engine      = new QyGoEngine();
    engine->modelPath = modelPath ? modelPath : "";
    engine->configPath = configPath ? configPath : "";

    g_input  = new GoInput();
    g_output = new GoOutput();

    std::cin.rdbuf(g_input);
    std::cout.rdbuf(g_output);

    engine->worker = std::thread([engine]() {
        std::vector<std::string> args = {
            "-config", engine->configPath,
            "-model",  engine->modelPath,
            "-override-config",
            "numSearchThreads=2,nnMaxBatchSize=1,logAllGTPCommunication=false,"
            "logSearchInfo=false,logToStderr=false,startupPrintMessageToStderr=false",
        };
        MainCmds::gtp(args);
    });

    return engine;
}

void qy_katago_send(QyGoEngine* engine, const char* line) {
    (void)engine;
    if (g_input == nullptr || line == nullptr) return;
    g_input->push(line);
}

int qy_katago_read_line(QyGoEngine* engine, char* out, int capacity, int timeoutMs) {
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

void qy_katago_destroy(QyGoEngine* engine) {
    if (engine == nullptr) return;

    if (g_input != nullptr) g_input->push("quit");
    if (engine->worker.joinable()) engine->worker.join();

    if (g_output != nullptr) g_output->close();
    if (g_input != nullptr) g_input->close();

    delete engine;
}
