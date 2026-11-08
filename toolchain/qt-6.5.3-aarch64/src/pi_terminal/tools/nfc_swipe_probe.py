#!/usr/bin/env python3
"""D 写：NFC 刷卡 / 设备配对的人工联调探针。

作用：起一个模拟 PBR1 桥板（真 PTY），把它的 tty 路径打印出来，然后按
--delay 秒后发一次桥板级 rfid_card 事件。终端用
``ORANGE_PI_CONTROL_DEVICE=<tty>`` 指过来即可，**不需要**真板子。

用法：
    python3 nfc_swipe_probe.py --uid a1b2c3d5 --delay 15
    # 另一个终端：
    ORANGE_PI_CONTROL_DEVICE=/dev/pts/N ./orange_pi_terminal

只读约定：本脚本只发事件，不写终端配置、不碰信任库、不改作者的任何脚本。
桥板逻辑复用 pi_terminal/tools/mock_bridge_multi.MultiSlotBridge。

已知边界（2026-10-29 实测）：
  * 未绑定的卡 → ``NO_MATCH``，登录页保持"选择用户"，不跳 PIN 页（符合设计）。
  * 已绑定的卡这条正向路径目前在产品里**走不到**：``securityService.bindCard``
    是 Q_INVOKABLE，但没有任何 QML 调用它，``CardBindingWindow`` 也从未被实例化，
    因此卡索引里不会有记录。要验证匹配逻辑只能靠 tests/card_matcher_test.cpp。
"""
import argparse
import sys
import time
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))

from mock_bridge_multi import MultiSlotBridge  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--uid', default='a1b2c3d5', help='卡 UID（hex，4/7/10 字节）')
    ap.add_argument('--delay', type=float, default=15.0, help='启动后多少秒刷卡')
    ap.add_argument('--hold', type=float, default=600.0, help='发完卡后保持桥板多久')
    args = ap.parse_args()

    bridge = MultiSlotBridge()
    print('CONTROL_DEVICE=' + bridge.path, flush=True)
    print('bridge ready, card swipe in %.0fs (uid=%s)' % (args.delay, args.uid), flush=True)
    time.sleep(args.delay)
    bridge.present_card(args.uid)
    print('CARD_SENT ' + args.uid, flush=True)
    time.sleep(args.hold)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
