# macos-vision-ocr

基于 macOS Vision、PDFKit 和 ImageIO 的离线命令行工具，支持图片、多帧图片与 PDF。默认中英混识，可直接读取 PDF 文本层，逐页输出文本、坐标和识别状态；不依赖第三方 OCR 模型或网络服务。

## 构建与安装

- 普通 OCR / PDF 文本提取需要 **macOS 13+**；实验性表格识别需要 **macOS 26+**。
- 编译需要 **Swift 6.2+、Xcode 26 或相应 Command Line Tools 的 macOS 26+ SDK**，其中包含 `RecognizeDocumentsRequest`。`Package.swift` 保留 macOS 13 部署目标和 Swift 5 语言模式；工具链版本不等于最低运行系统版本。
- 产物使用当前机器架构，**不是 Universal Binary**。Intel 与 Apple Silicon 的可用加速设备由系统决定，不保证使用 ANE。

```bash
./build.sh                       # SwiftPM debug 增量构建，复制到 ./build/ocr
./build.sh --release             # 显式构建优化版
./build/ocr --version
./build.sh --install             # 默认构建 release，并原子安装到 ~/.local/bin/ocr
./build.sh --install /usr/local/bin/ocr
```

仍接受 `./build.sh /其他路径/ocr` 形式的显式安装路径。开发构建默认 debug；安装默认 release，也可显式选择配置。安装时先生成完整临时文件，再替换目标。请确保安装目录在 `PATH` 中；下列 `ocr` 也可替换为 `./build/ocr`。

## 开发、Run 与诊断

项目是一个无外部依赖的 SwiftPM 命令行包，产品名为 `ocr`，可在 Xcode 中打开 `Package.swift`。普通终端支持 `swift build`、`swift run ocr --help` 与 `swift test`。项目脚本统一将 SwiftPM 缓存和编译中间文件放在 `.build/` 中。

```bash
./script/build_and_run.sh                            # 构建 debug 并显示帮助
./script/build_and_run.sh -- --json 图片.png          # 转发 OCR 参数
./script/build_and_run.sh --verify                   # 验证短命 CLI 的版本输出与退出状态
./script/build_and_run.sh --debug -- --json 图片.png  # LLDB 调试
./script/doctor.sh                                   # 检查系统、工具链与产物，不运行 OCR
```

Codex 的 Run 动作由 `.codex/environments/environment.toml` 指向同一个运行脚本。脚本构建日志写入 stderr，OCR 输出保留在 stdout；无参数时仅显示帮助。CLI 没有常驻应用进程，运行入口不会按名称终止其他 `ocr` 任务；中断作用于当前启动的进程。构建或调试不隐式安装命令。

SwiftPM 的 manifest 沙箱与 Vision 的 ANE 访问限制是不同的环境问题。若当前 Agent 沙箱不允许 SwiftPM 启动自己的沙箱或访问必要服务，应按当前环境申请执行权限；项目脚本不会自动关闭沙箱。`doctor.sh` 的静态环境检查通过不代表 OCR 模型访问权限已通过。

## 常用命令

```bash
ocr 图片.png
ocr --no-correction 标准.pdf
ocr --pages 1,3-5 --jsonl --progress -o 结果.jsonl 文档.pdf
ocr --mode text --json -o 文本层.json 电子版.pdf
ocr --mode auto --page-marker 混合页文档.pdf
ocr --rotate 90 --region 0.1,0.2,0.8,0.5 --json 截图.jpg
ocr --reading-order column 双栏.pdf
ocr --custom-words 术语.txt --candidates 3 --json 扫描件.pdf
ocr --fast --list-langs
ocr -- --以减号开头的文件.png
```

文件按命令行顺序处理，页面/图片帧逐个处理。`--pages` 从 **1** 开始，选择结果排序并去重；`--pages 3,1,3` 处理第 1、3 页。选择范围应用于每个输入文件，越界时该文件报错，其他文件继续。

## PDF 模式与阅读顺序

| 模式 | 行为 |
|---|---|
| `--mode ocr` | 默认，保持旧版始终栅格化后 OCR 的行为；图片也使用此路径。 |
| `--mode text` | 仅提取 PDF 文本层，不运行 OCR；无可提取文本时页面为 `empty`。不接受图片或 `--region`。 |
| `--mode auto` | 逐页先提取文本层，有文字即使用该层，无文字才 OCR；图片直接 OCR。PDF 带 `--region` 时统一 OCR，并记录 `region_requires_ocr` 警告。 |

`text` / `auto` 检出连续 `/G21/G22` 字形编号或较高比例替代字符、私用码位等明显乱码时，该页报 `text_layer_unusable`，**不会自动绕过文本层去 OCR**。请先检查 CID / ToUnicode 码表；明确需要识别页面图像时用 `--mode ocr`。乱码检测是保守启发式，不保证发现所有错误码表。

同一页同时存在可提取文字和扫描图时，`auto` 只返回现有文本层，不能保证图片中的文字也被识别；此类页面要完整 OCR 应选 `ocr`。`--page-box crop` 的文本提取仅保留完全落在框内的行，跨边界行应改用 OCR。

`--reading-order vision` 保留引擎原始顺序，`row` 聚合同一行后从左到右，`column` 尝试按栏及跨栏标题组织顺序。默认纯文本为 `vision`，其他格式为 `row`。行/栏排序是几何启发式，复杂排版仍需核对。

## 参数

| 参数 | 默认值 / 作用 |
|---|---|
| `-l, --langs zh-Hans,en-US` | 逗号分隔语言；默认简体中文、英语。按当前引擎及精确/快速模式验证支持情况。 |
| `-f, --fast` | 快速模式；默认精确模式。 |
| `--no-correction` | 关闭语言纠错，适合标准、术语、型号与编号。 |
| `--custom-words 文件` | UTF-8 词典，每行一词，忽略空行、去重；不能与 `--no-correction` 同用。 |
| `--candidates 1..10` | 每行最多保留的识别候选数，默认 1；结构化输出中大于 1 时附带候选。 |
| `--mode ocr\|text\|auto` | 默认 `ocr`，详见上文。 |
| `--dpi 正数` | PDF 栅格化分辨率，默认 200；必须是有限正数。单页栅格上限 100 MP，超限明确报错。 |
| `--pages 1,3-5` | 选择原始页/帧，不选则处理全部。 |
| `--rotate 0\|90\|180\|270` | 顺时针额外旋转，默认 0；叠加 PDF 自带旋转或图片 EXIF 方向。 |
| `--region x,y,w,h` | 方向归一化及旋转后页面左上原点区域，各值在 0..1，宽高为正且不越界。 |
| `--page-box media\|crop` | PDF 边界，默认 `media`。 |
| `--reading-order vision\|row\|column` | 指定行序。 |
| `--tables` | 实验性表格识别；仅支持精确 `ocr` 模式。 |
| `--format text\|json\|jsonl\|csv\|markdown` | 默认 `text`；CSV / Markdown 自动启用 `--tables`。 |
| `--json`、`--jsonl` | 对应格式快捷参数；不能同时指定不同格式。 |
| `--page-marker` | 文本增加文件和原始页码标记；多文件文本始终有文件标记。 |
| `--progress` | 逐页进度写 stderr，不混入结构化 stdout。 |
| `-o, --output 文件` | 默认 stdout；指定文件时先写同目录临时文件，完成后原子替换。 |
| `--list-langs` | 无需输入文件；先解析全部选项，再列出对应模式/引擎支持语言。 |
| `--version`、`-h, --help` | 版本或帮助，无需输入文件。 |
| `--` | 后续参数全部视为输入文件名。 |

`--tables` / CSV / Markdown 不能与 `--fast`、`--mode text`、`--mode auto` 同用。`--region` 目前在生成完整页图像后裁剪，不会绕过完整页的 100 MP 限制。

## JSON 与坐标契约

`--json` 使用 schema 2，保留旧版最外层数组及 `file / pages / page / lines / bbox / text` 字段，按页流式写入，不累计整份文档结果。新增字段提供状态、尺寸、方向、来源与置信度；消费者应忽略不认识的新增字段。

简化示例（省略部分元数据）：

```json
[
  {
    "schemaVersion": 2,
    "toolVersion": "0.2.1",
    "file": "标准.pdf",
    "pages": [
      {
        "page": 0,
        "status": "ok",
        "source": "ocr",
        "width": 595,
        "height": 842,
        "unit": "pt",
        "coordinateSpace": "oriented-page-top-left",
        "rotation": 0,
        "lines": [
          {"bbox": [61.1, 70.9, 151.5, 83.2], "text": "GB/T 21085—2020", "confidence": 0.98, "sourceIndex": 0}
        ],
        "warnings": []
      }
    ],
    "status": "ok",
    "pageCount": 1,
    "failedPages": 0
  }
]
```

- 结构化 `page` 从 **0** 开始，始终是源 PDF 页号或图片帧号；前面页面失败、未被选择时不重新编号。`--pages` 和文本页码标记从 **1** 开始。
- `bbox` 为 `[x0,y0,x1,y1]`，原点位于方向归一化及旋转后的完整页左上。PDF 的 `unit` 为 `pt`（72 点/英寸），图片为 `px`。`width` / `height` 描述所选页面框或方向归一化后的完整图片。
- `--region` 只限制识别区域，坐标仍相对于完整页，不以裁剪区域重新归零。裁剪边界按像素取整。PDF `crop` 使用所选 CropBox 的页面空间。
- PDF `rotation` 包含自带旋转及额外旋转；图片 `rotation` 仅表示额外旋转，`sourceOrientation` 单独记录原始 EXIF 方向 1..8，包括镜像方向。
- 成功页 `source` 为 `ocr` 或 `text`；失败页记录请求模式。`engine` / `engineRevision`（如有）说明引擎。直接文本提取没有 OCR 置信度或候选。`sourceIndex` 可追溯排序前行序。
- 页面 `status` 为 `ok`、`empty` 或 `error`，`empty` 是正常成功。失败页带 `error: {code,message}`。文档状态为 `ok`、`partial` 或 `error`，`pageCount` 包含已输出失败页，`failedPages` 统计失败页；文件级失败另有文档 `error`。

`--jsonl` 每条记录占一行，可在任务未结束时逐页消费：

- `type: "page"`：平铺完整 `PageResult` 字段，加 `file`、`schemaVersion`、`toolVersion`。
- `type: "file_error"`：文件无法读取、选择页越界等文件级错误；含 `file`、`error`、版本字段。
- `type: "file_end"`：每个文件结束标记；含 `status`、`pageCount`、`failedPages` 和版本字段。

页级失败以 `type:"page", status:"error"` 输出，后续页继续。普通 JSON 必须等数组写完才是完整 JSON；需要边读边处理时使用 JSONL。

## 实验性表格识别

表格模式使用 macOS 26+ 的 `Vision.RecognizeDocumentsRequest`，返回行列、单元格坐标及合并范围。普通文字 OCR 仍使用 `VNRecognizeTextRequest`。

```bash
ocr --tables --json -o 表格.json 表格.pdf
ocr --format csv -o 单元格.csv 表格.pdf
ocr --format markdown -o 表格.md 表格.png
ocr --tables --list-langs
```

JSON 的 `tables` 含 `bbox / rows / columns / cells`，单元格含 `row / column / rowSpan / columnSpan / bbox / text`。行、列和表格索引从 0 开始；跨度为覆盖数量。

CSV 是固定列长表：`file,page,table,row,column,row_span,column_span,text`，每个网格位置一行，便于跨页、跨表合并分析。逗号、双引号和换行按 CSV 规则转义。Markdown 为每张表保留文件/页/表定位标题及网格。两种输出中，合并区域只有左上格包含文字，覆盖位置为空；CSV 原样保存文本，不改写 OCR 内容。

此功能尚需真实中文表格、复杂合并单元格及扫描质量样本验证，不承诺识别准确率。未检测出表格时可能有正文但没有表格输出；JSON 页面记录 `no_tables_detected` 警告。置信度属于引擎输出，不等于经过校准的正确率。

## 错误、输出安全与运行环境

退出码 `0` 表示全部成功（包含正常空白页），`1` 表示文件/页面识别或输出失败，`2` 表示参数解析、值域或组合错误。依赖实际文件才能发现的错误，例如选择页越界，作为文件级失败返回 `1`。诊断写 stderr。

部分文件或页面失败时仍保留已完成结果并继续处理，最终返回 `1`。使用 `--output` 时，只要输出写入正常，包含失败信息的最终结果也会原子提交；写入、序列化或提交失败则保留原目标。异常终止不保证清理临时文件。输出禁止与输入文件/词典相同或互为硬链接，也禁止覆盖输出符号链接。使用 shell 的 `> 输入文件` 重定向会先被 shell 截断，工具无法保护，请使用 `--output`。

首次识别可能包含模型预热。受限执行环境可能因 ANE / XPC / IOKit 访问限制出现 `nilError` 或 `e5rtError`；按当前环境权限机制处理，不将这些错误等同于正常无文字。此工具不会自行修改 sandbox 配置。

## 验证与项目结构

```bash
./Tests/run.sh                         # XCTest + Python CLI 集成测试
./script/swiftpm.sh test --filter GeometryTests/testGeometry
# 使用指定二进制做 CLI 集成验证，XCTest 仍测试当前源码：
OCR_BINARY="$PWD/build/ocr" ./Tests/run.sh
```

测试使用生成的 PDF 文本层与小图片，以及合成坐标和表格数据，检查参数/退出码、分页、坐标变换与裁剪、阅读顺序、流式格式、原子输出和输入保护；**不调用 OCR 模型、不安装命令、不下载数据**。这些测试不能替代真实 OCR、表格效果、旧版 macOS 或其他硬件架构的验证。

另有可选的真实 Vision 端到端测试，需要 macOS 26+、已构建二进制及执行环境允许的正常 Vision 访问权限：

```bash
./Tests/ocr_smoke.sh
```

默认验证最近一次 `build.sh` 生成的 `build/ocr`；也可通过 `OCR_BINARY` 指定其他已有产物。

它生成小型中英文图片和扫描 PDF，实际调用 OCR，检查候选/置信度、旋转与页号、区域坐标、表格 JSON / CSV。该固定样本已在本机正常权限下通过，但不代表真实复杂文档准确率；当前受限 sandbox 可能报 `nilError`，应通过当前环境权限机制运行，不能擅自关闭 sandbox。

`Package.swift` 定义 `OCR` 可执行目标及 `OCRTests` 原生测试目标；`ocr.swift` 为命令入口，`Sources/` 按参数、几何、识别、处理流程和输出分工。`Tests/` 存放 XCTest、CLI 回归与显式运行的 OCR 冒烟测试。`.build/` 存放增量编译缓存，`build/ocr` 是供手动调用的暂存产物；运行脚本和安装直接使用本次配置的 SwiftPM 产物，两处构建目录均不入库。
