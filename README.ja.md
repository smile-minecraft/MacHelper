<p align="center">
  <img src="docs/images/mascot.gif" width="240" alt="MacHelper のスライム：呼吸、手を振る、ジャンプ、お祝い">
</p>

<h1 align="center">MacHelper</h1>

<p align="center">
  <b>すべてが Mac の中で完結するユーティリティ。システムモニタ、ファン制御、クリーンアップ、ディスク分析をひとつのメニューバー App に。</b>
</p>

<p align="center">
  <a href="https://github.com/smile-minecraft/MacHelper/releases/latest"><img src="https://img.shields.io/github/v/release/smile-minecraft/MacHelper?label=release&color=5b8def" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-1f2430" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-1f2430" alt="Apple Silicon">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-4cc38a" alt="MIT"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.zh-Hant.md">繁體中文</a> · <a href="README.zh-Hans.md">简体中文</a> · 日本語 · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a>
</p>

<p align="center">
  <img src="docs/images/menubar.png" width="320" alt="メニューバーの MacHelper：CPU の折れ線、メモリ、温度">
</p>

<p align="center">
  <img src="docs/images/overview.png" width="860" alt="概要：ヘルススコア、リアルタイムの値、リソースを多く使っている App">
</p>

<p align="center">
  <a href="#インストール"><b>インストール</b></a> ·
  <a href="#機能"><b>機能</b></a> ·
  <a href="#初回起動"><b>初回起動</b></a> ·
  <a href="#コマンドライン"><b>コマンドライン</b></a> ·
  <a href="#ソースからのビルド"><b>ソースからのビルド</b></a>
</p>

---

MacHelper が測定・保存するデータはすべて Mac の中にとどまります。アカウントも分析もなく、アップデートの確認以外にネットワークは使いません。macOS 14 以降の Apple Silicon Mac が必要で、MIT ライセンスのオープンソースです。

## インストール

```sh
brew install --cask smile-minecraft/tap/machelper
```

[Releases](https://github.com/smile-minecraft/MacHelper/releases/latest) から `MacHelper-<バージョン>.dmg` をダウンロードし、MacHelper を「アプリケーション」にドラッグしてもインストールできます。各リリースは Developer ID で署名され Apple の公証を受けているため、そのまま開けます。チェックサムはリリースページの `SHA256SUMS.txt` にあります。

MacHelper は自動で最新の状態を保ちます。バックグラウンドの確認で新しいバージョンが見つかると、サイドバー、メニューバーのパネル、設定に **x.y.z にアップデート** ボタンが表示され、クリックしたときだけインストールします。アップデートのウインドウには、App の表示言語で新機能が表示されます。

## 機能

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>モニタ</h3>
      <img src="docs/images/monitor.png" alt="モニタ：CPU、GPU、メモリ、温度、ファン、電力のグラフと警告ライン">
      <p>CPU（高性能コアと高効率コア）、GPU、メモリプレッシャー、温度、ファン、電力、バッテリー、ディスクとネットワークの速度。リアルタイムのグラフと 1 分ごとの履歴を 1 時間、24 時間、7 日間で表示でき、メモリと温度には警告ラインがあります。メニューバーの各項目は、テキスト、折れ線、縦棒、バー、リング、ブロック、ヒートピル、2 本線から選べます。</p>
    </td>
    <td width="50%" valign="top">
      <h3>ヘルスチェック</h3>
      <img src="docs/images/health.png" alt="ヘルスチェック：スコア、直近 24 時間の値、空き容量の推移">
      <p>直近数時間の履歴、空き容量、バックグラウンド項目からヘルススコアを出し、下がった理由と対処法を示します。Gatekeeper、FileVault、ファイアウォール、システム整合性保護、セキュリティアップデートの自動インストール、XProtect も読み取り専用で確認します。</p>
    </td>
  </tr>
  <tr>
    <td colspan="2" valign="top">
      <h3>ディスク分析</h3>
      <img src="docs/images/disk.png" alt="ディスク分析：ホームフォルダのサンバーストと大きなフォルダ">
      <p>サンバーストとツリーマップ（どのフォルダもクリックするとそのまま開きます）、種類と期間で絞り込める大きなファイル、重複ファイル（APFS のクローンとハードリンクを区別）、前回のスキャンからの変化、長く使われていない大きなファイルや膨らんだフォルダを見つける容量の提案。項目をコレクターにドラッグすれば、まとめてゴミ箱に入れられます。</p>
    </td>
  </tr>
</table>

| | |
|---|---|
| **ファン制御** | 自動、固定速度、温度カーブ（静音、バランス、パフォーマンス、カスタム）、「上げるだけ」モード、安全上限、実行中の App や電源に応じたプロファイルの自動切り替え。 |
| **ワンクリック最適化** | プレビューしてからクリーン：低リスクのキャッシュは削除し、中・高リスクの項目はゴミ箱へ。保護されたパス、クリーンしないリスト、操作ログ、メンテナンス作業、プロジェクトのビルド成果物の削除、定期的な自動クリーン。 |
| **App のアンインストール** | バンドル ID、内蔵ヘルパー、エンタイトルメント、コンテナの情報、launchd の所有者、Homebrew の zap リスト、App ごとのルールから、App が残したものを探します。名前だけで一致した項目には確認用の印が付き、削除済み App の残りも探せます。 |
| **起動項目** | 自分の Launch Agent（無効化、有効化、削除）、すべてのユーザの Agent、システムの Daemon。所属する App と壊れた項目を示します。 |
| **Homebrew のアップデート** | Homebrew でインストールした App をアップデートします。 |
| **AI エージェントのスキル** | Claude Code と Codex にスキルを追加して、MacHelper を安全に使わせます。必ず先にプレビューし、削除する前に確認します。 |
| **通知** | CPU 温度が高いとき、メモリプレッシャーが危険なとき、ディスクの空きが少ないときに知らせます。 |
| **オプションの履歴** | プロセス、センサー、コアの履歴はデフォルトでオフ。プロセス履歴は名前、CPU、メモリだけを記録し（パス、引数、ユーザ名は記録しません）、保存期間は 1〜30 日です。 |
| **スライム** | マスコットは Mac の状態に合わせて色が変わり（青、黄、赤）、クリック、ポインタ、ドラッグや、高温・クリーン完了などのイベントに反応します。「視差効果を減らす」と VoiceOver に対応しています。 |
| **言語** | 英語、繁体字中国語、簡体字中国語、日本語、韓国語、スペイン語。「設定」→「一般」→「言語」でシステムとは別の言語を選べます。 |

## 初回起動

MacHelper は 2 つの権限を 1 つずつ案内します。どちらも任意で、それ以外の機能はなくても使えます。

1. **フルディスクアクセス** があると、ディスク分析とクリーンアップが「メール」のダウンロードやほかの App のキャッシュなど保護された場所を見られます。**「システム設定」→「プライバシーとセキュリティ」→「フルディスクアクセス」** で MacHelper をオンにすると、案内のシートが自動で気づきます。システム整合性保護の対象フォルダはオンにしても読めず、ディスク分析では別に一覧表示します。
2. **Helper** は、ファン制御、システムのキャッシュとログのクリーン、システムのバックグラウンド項目、システムプロセスの使用量を担う小さな root デーモンです。案内に沿ってインストールし、**「システム設定」→「一般」→「ログイン項目と機能拡張」** で許可すると、応答することを確認します。呼び出し元のコード署名はすべて検証します。オフのあいだは、サイドバー下部の **Helper を設定…** から案内を開き直せます。

## コマンドライン

App には `machelper` コマンドが入っています（Homebrew がリンクを作成します）。どのコマンドもデフォルトはプレビューのみで `--json` に対応しているので、スクリプトや AI エージェントで使いやすくなっています。概要は `machelper guide`、各コマンドの説明は `machelper <コマンド> --help` で確認できます。

```sh
machelper status --json                 # 現在のすべての値
machelper clean                         # クリーンされる項目をプレビュー
machelper clean --max-risk low --yes    # 低リスクの項目だけをクリーン
```

## ソースからのビルド

Xcode 16 以降と [XcodeGen](https://github.com/yonaskolb/XcodeGen) が必要です。

```sh
xcodegen generate
scripts/install.sh          # Release ビルド → /Applications/MacHelper.app、その後再起動
swift test                  # Swift パッケージのユニットテスト
```

署名、プロジェクトの構成、スクリーンショットの作り方、リリースの手順（各言語のアップデート情報を含む）、翻訳の方法は[英語の README](README.md) を見てください。

## ライセンス

MIT。[LICENSE](LICENSE) を参照してください。
