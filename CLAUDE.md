# moonlight-ios（kiyor fork）

## 北极星
主人在 iPhone 上串流自己的 PC，阿西西安卓版里他用得到的痛点功能逐个落到 iOS。
判据：每个痛点在主人真机上串流实测好用，不以「跟安卓版一样」为准。

## 入口
- 上游 moonlight-stream/moonlight-ios（remote `upstream`），fork `kiyor/moonlight-ios`
- 参考实现：Axixi2233/moonlight-android（Java，clone 在 /tmp/mla，可重新 clone）
- 真机编译安装：`scripts/run-device.sh`（默认 iPhone19,3，`MODEL=` 可改；Bundle ID `me.kiyor.moonlight`，Team 取自 novel-reader-ios）
- 签名用命令行覆盖，不改 pbxproj，方便 rebase 上游

## 痛点清单
（待主人给）
