// test_hook.cpp —— 独立验证 kc_hook
//
//   test_hook.exe --selftest      键名归一化断言（不需要人打字）
//   test_hook.exe [秒数]          实时抓键 + 汇总（用来验证「非焦点也能抓到」）
#include "kc_hook.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

struct Case {
	uint32_t vk;
	uint32_t sc;
	bool extended;
	const char *expect;
	const char *why;
};

int run_selftest() {
	// 扫描码写 0 的那几条是在钉住一个实测出来的 bug：
	// SendKeys/SendInput 造的事件没有扫描码，早期版本只按扫描码查表，结果全变成 "sc00"
	const Case cases[] = {
		{ 'A', 0x1E, false, "a", "Shift+A 归一化到基准键位小写" },
		{ 'A', 0x00, false, "a", "合成输入无扫描码也要认得出" },
		{ 0x00, 0x1E, false, "a", "vk 缺失时用扫描码兜底" },
		{ '0', 0x0B, false, "0", "数字行" },
		{ VK_RETURN, 0x1C, false, "enter", "主回车" },
		{ VK_RETURN, 0x1C, true, "kp_enter", "小键盘回车，靠 extended 区分" },
		{ VK_SPACE, 0x39, false, "space", "空格" },
		{ VK_BACK, 0x0E, false, "backspace", "退格" },
		{ VK_TAB, 0x0F, false, "tab", "Tab" },
		{ VK_ESCAPE, 0x01, false, "esc", "Esc" },
		{ VK_LSHIFT, 0x2A, false, "shift", "左 Shift" },
		{ VK_RSHIFT, 0x36, false, "shift", "右 Shift（v0 左右不区分）" },
		{ VK_LCONTROL, 0x1D, false, "ctrl", "左 Ctrl" },
		{ VK_RMENU, 0x38, true, "alt", "右 Alt（AltGr）" },
		{ VK_LEFT, 0x4B, true, "left", "方向键左" },
		{ VK_DELETE, 0x53, true, "delete", "Delete" },
		{ VK_NUMPAD0, 0x52, false, "kp_0", "小键盘 0" },
		{ VK_MULTIPLY, 0x37, false, "kp_multiply", "小键盘 *" },
		{ VK_F1, 0x3B, false, "f1", "F1" },
		{ VK_F8, 0x00, false, "f8", "F8（合成输入无扫描码）" },
		{ VK_F24, 0x00, false, "f24", "F24" },
		{ VK_LWIN, 0x5B, true, "win", "左 Win" },
		{ VK_OEM_1, 0x27, false, "semicolon", "分号" },
		{ VK_OEM_PERIOD, 0x34, false, "dot", "句点" },
		{ 0x00, 0x00, false, "vk00_sc00", "两个都认不出 → 明确记未知，不假装" },
	};

	int failed = 0;
	printf("===== 键名归一化自检（%d 条）=====\n", (int)(sizeof(cases) / sizeof(cases[0])));
	for (const Case &c : cases) {
		kc::KeyEvent e;
		e.vk = c.vk;
		e.scancode = c.sc;
		e.extended = c.extended;
		e.is_down = true;
		const std::string got = kc::key_name(e);
		const bool ok = (got == c.expect);
		if (!ok) {
			failed++;
		}
		printf("%s vk=0x%02X sc=0x%02X ext=%d → %-12s (期望 %-12s)  %s\n",
				ok ? "PASS" : "FAIL", c.vk, c.sc, c.extended ? 1 : 0,
				got.c_str(), c.expect, c.why);
	}
	printf("\n%d 通过，%d 失败\n",
			(int)(sizeof(cases) / sizeof(cases[0])) - failed, failed);
	return failed == 0 ? 0 : 1;
}

int run_live(int seconds) {
	if (!kc::hook_start()) {
		printf("HOOK FAILED  GetLastError=%lu\n", (unsigned long)GetLastError());
		return 1;
	}
	printf("HOOK OK  这个进程不需要有焦点；去别的窗口打字，这里应该照样能看到\n");
	printf("抓 %d 秒 ...\n\n", seconds);

	std::map<std::string, int> counts;
	int downs = 0;
	int ups = 0;
	int repeats = 0;

	const auto t0 = std::chrono::steady_clock::now();
	while (std::chrono::duration_cast<std::chrono::seconds>(
				   std::chrono::steady_clock::now() - t0)
					.count() < seconds) {
		kc::KeyEvent ev[64];
		const size_t n = kc::hook_poll(ev, 64);
		for (size_t i = 0; i < n; ++i) {
			if (!ev[i].is_down) {
				ups++;
				continue;
			}
			downs++;
			if (ev[i].repeated) {
				repeats++;
			}
			const std::string name = kc::key_name(ev[i]);
			counts[name]++;
			printf("DOWN %-12s vk=0x%02X sc=0x%02X ext=%d repeat=%d\n",
					name.c_str(), ev[i].vk, ev[i].scancode, ev[i].extended ? 1 : 0,
					ev[i].repeated ? 1 : 0);
		}
		std::this_thread::sleep_for(std::chrono::milliseconds(8));
	}

	kc::hook_stop();

	printf("\n===== 汇总 =====\n");
	printf("按下 %d 下，抬起 %d 下，长按自动重复 %d 下，队列丢弃 %llu 条\n",
			downs, ups, repeats, (unsigned long long)kc::hook_dropped());

	std::vector<std::pair<int, std::string>> sorted;
	for (const auto &kv : counts) {
		sorted.push_back({ kv.second, kv.first });
	}
	std::sort(sorted.begin(), sorted.end(), [](const auto &a, const auto &b) {
		if (a.first != b.first) return a.first > b.first;
		return a.second < b.second;
	});
	printf("不同键 %d 个，Top 10：\n", (int)sorted.size());
	for (size_t i = 0; i < sorted.size() && i < 10; ++i) {
		printf("  %-12s %5d\n", sorted[i].second.c_str(), sorted[i].first);
	}
	return 0;
}

} // namespace

int main(int argc, char **argv) {
	if (argc > 1 && strcmp(argv[1], "--selftest") == 0) {
		return run_selftest();
	}
	const int seconds = (argc > 1) ? atoi(argv[1]) : 10;
	return run_live(seconds);
}
