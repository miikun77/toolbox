# toolbox

個人的に使っているスクリプト・設定ファイルをまとめたリポジトリ。

## ツール一覧

| フォルダ | 概要 |
|---|---|
| [upki-lego/](./upki-lego/) | UPKI ACME証明書をlegoで自動取得・更新するセットアップスクリプト |

---

## upki-lego

NII UPKI電子証明書発行サービスの ACME 対応証明書を、lego（Docker）で取得し、systemd.timer で自動更新するセットアップスクリプト。

関連記事 → https://zenn.dev/miikun77/articles/upki-lego-ssl-auto-renew

### 前提

- Docker・Nginx がインストール済み
- UPKIのEABクレデンシャル（KIDとHMAC）が発行済み

### 使い方

```bash
bash upki-lego/setup.sh
```

対話形式でKID・HMAC・ドメイン・メールアドレスを入力すると、以下を自動でセットアップします。

1. Nginx の HTTP-01 チャレンジ受け口を作成
2. lego（Docker）で証明書を取得
3. Nginx に SSL 設定を追記
4. systemd.timer で毎日自動更新

2つ目以降のドメインも同じコマンドで追加でき、既存の `lego-renew.service` に `ExecStart` を追記します（timer の再作成は不要）。
