'use strict';

const {
  Client,
  GatewayIntentBits,
  ActionRowBuilder,
  ButtonBuilder,
  ButtonStyle,
  EmbedBuilder,
  ModalBuilder,
  TextInputBuilder,
  TextInputStyle,
} = require('discord.js');
const http = require('http');
const { execFile } = require('child_process');
const path = require('path');
const fs = require('fs');

// .env をプロセス環境変数に読み込む（launchd では自動で読まれないため）
const envPath = path.join(__dirname, '..', '.env');
if (fs.existsSync(envPath)) {
  for (const line of fs.readFileSync(envPath, 'utf8').split('\n')) {
    const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (m && !(m[1] in process.env)) {
      process.env[m[1]] = m[2].replace(/^["']|["']$/g, '');
    }
  }
}

const TOKEN = process.env.DISCORD_NOTIFY_BOT_TOKEN;
const CHANNEL_ID = process.env.DISCORD_CHANNEL_ID;
const PORT = parseInt(process.env.NOTIFY_PORT || '8787', 10);
const HANDLERS = path.join(__dirname, '..', 'skills', 'gmail', 'handlers');
const REPO_DIR = path.join(__dirname, '..');

if (!TOKEN) { console.error('[bot] DISCORD_NOTIFY_BOT_TOKEN not set'); process.exit(1); }
if (!CHANNEL_ID) { console.error('[bot] DISCORD_CHANNEL_ID not set'); process.exit(1); }

const client = new Client({ intents: [GatewayIntentBits.Guilds] });

// spam候補: messageId → {from, account}（メモリ内。bot再起動でリセット）
const spamCandidates = new Map();

// チャンネルキャッシュ
let cachedChannel = null;
async function getChannel() {
  if (!cachedChannel) cachedChannel = await client.channels.fetch(CHANNEL_ID);
  return cachedChannel;
}

// ハンドラースクリプトを実行して stdout を返す
function runHandler(script, args, stdinData) {
  return new Promise((resolve, reject) => {
    const proc = execFile(
      '/bin/bash',
      [path.join(HANDLERS, script), ...args],
      { cwd: REPO_DIR, timeout: 90000, killSignal: 'SIGTERM' },
      (err, stdout, stderr) => {
        if (stderr) process.stderr.write(`[bot] ${script}: ${stderr}`);
        if (err) {
          const msg = err.killed ? 'タイムアウト（90秒）' : (stderr.trim() || err.message);
          reject(new Error(msg));
        } else {
          resolve(stdout.trim());
        }
      }
    );
    if (stdinData != null) {
      proc.stdin.write(stdinData);
      proc.stdin.end();
    }
  });
}

// Discord イベント
client.once('ready', () => {
  console.log(`[bot] Logged in as ${client.user.tag}`);
  startHttpServer();
});

client.on('interactionCreate', async (interaction) => {
  // 送信ボタン
  if (interaction.isButton() && interaction.customId.startsWith('send:')) {
    const rest = interaction.customId.slice('send:'.length);
    const colonIdx = rest.indexOf(':');
    const draftId = rest.slice(0, colonIdx);
    const alias = rest.slice(colonIdx + 1);

    await interaction.deferReply({ ephemeral: true });
    try {
      await runHandler('send.sh', [draftId, alias], null);

      // ボタンを無効化してメッセージを更新
      if (interaction.message.components.length > 0) {
        const disabledRow = new ActionRowBuilder().addComponents(
          interaction.message.components[0].components.map(c =>
            ButtonBuilder.from(c.toJSON()).setDisabled(true)
          )
        );
        await interaction.message.edit({
          content: interaction.message.content + '\n✅ **送信済み**',
          components: [disabledRow],
        });
      }
      await interaction.editReply({ content: '送信しました。' });
    } catch (e) {
      console.error('[bot] send failed:', e.message);
      await interaction.editReply({ content: `送信に失敗しました: ${e.message}` });
    }
    return;
  }

  // 改稿ボタン → モーダル表示
  if (interaction.isButton() && interaction.customId.startsWith('revise:')) {
    const modalCustomId = 'revise-submit:' + interaction.customId.slice('revise:'.length);
    const modal = new ModalBuilder()
      .setCustomId(modalCustomId)
      .setTitle('下書きを改稿');
    const input = new TextInputBuilder()
      .setCustomId('instruction')
      .setLabel('改稿の指示')
      .setStyle(TextInputStyle.Paragraph)
      .setPlaceholder('例: もっと丁寧に / 英語で書き直して / 要点を3行に')
      .setRequired(true);
    modal.addComponents(new ActionRowBuilder().addComponents(input));
    await interaction.showModal(modal);
    return;
  }

  // 迷惑メール確認ボタン
  if (interaction.isButton() && interaction.customId.startsWith('spam-confirm:')) {
    const rest = interaction.customId.slice('spam-confirm:'.length);
    const colonIdx = rest.indexOf(':');
    const messageId = rest.slice(0, colonIdx);
    const alias = rest.slice(colonIdx + 1);

    await interaction.deferReply({ ephemeral: true });
    const candidate = spamCandidates.get(messageId) || {};
    try {
      const stdinData = JSON.stringify({ messageId, account: alias, from: candidate.from || '' });
      await runHandler('spam-confirm.sh', [messageId, alias], stdinData);

      if (interaction.message.components.length > 0) {
        const disabledRow = new ActionRowBuilder().addComponents(
          interaction.message.components[0].components.map(c =>
            ButtonBuilder.from(c.toJSON()).setDisabled(true)
          )
        );
        await interaction.message.edit({
          content: interaction.message.content + '\n🚫 **迷惑メールに設定済み**',
          components: [disabledRow],
        });
      }
      await interaction.editReply({ content: '迷惑メールに設定し、ブロックリストに追加しました。' });
      spamCandidates.delete(messageId);
    } catch (e) {
      console.error('[bot] spam-confirm failed:', e.message);
      await interaction.editReply({ content: `失敗しました: ${e.message}` });
    }
    return;
  }

  // 迷惑メールではない（アローリスト追加）
  if (interaction.isButton() && interaction.customId.startsWith('spam-reject:')) {
    const rest = interaction.customId.slice('spam-reject:'.length);
    const colonIdx = rest.indexOf(':');
    const messageId = rest.slice(0, colonIdx);

    await interaction.deferReply({ ephemeral: true });
    const candidate = spamCandidates.get(messageId) || {};
    try {
      const stdinData = JSON.stringify({ from: candidate.from || '', account: candidate.account || '' });
      await runHandler('spam-reject.sh', [], stdinData);

      if (interaction.message.components.length > 0) {
        const disabledRow = new ActionRowBuilder().addComponents(
          interaction.message.components[0].components.map(c =>
            ButtonBuilder.from(c.toJSON()).setDisabled(true)
          )
        );
        await interaction.message.edit({
          content: interaction.message.content + '\n✅ **通常メールとして確認済み**',
          components: [disabledRow],
        });
      }
      await interaction.editReply({ content: 'アローリストに追加しました。次回から迷惑メール候補にしません。' });
      spamCandidates.delete(messageId);
    } catch (e) {
      console.error('[bot] spam-reject failed:', e.message);
      await interaction.editReply({ content: `失敗しました: ${e.message}` });
    }
    return;
  }

  // 改稿モーダル送信
  if (interaction.isModalSubmit() && interaction.customId.startsWith('revise-submit:')) {
    const rest = interaction.customId.slice('revise-submit:'.length);
    const colonIdx = rest.indexOf(':');
    const draftId = rest.slice(0, colonIdx);
    const alias = rest.slice(colonIdx + 1);
    const instruction = interaction.fields.getTextInputValue('instruction');

    await interaction.deferReply({ ephemeral: true });
    try {
      const preview = await runHandler('revise.sh', [draftId, alias], instruction);
      await interaction.editReply({
        content: `改稿しました。\n\`\`\`\n${preview}\n\`\`\``,
      });
    } catch (e) {
      console.error('[bot] revise failed:', e.message);
      await interaction.editReply({ content: `改稿に失敗しました: ${e.message}` });
    }
  }
});

// HTTP サーバー（notify.sh からの通知を受けて Discord に投稿）
function startHttpServer() {
  const server = http.createServer(async (req, res) => {
    if (req.method !== 'POST' || req.url !== '/notify') {
      res.writeHead(404);
      res.end();
      return;
    }
    let body = '';
    req.on('data', d => { body += d; });
    req.on('end', async () => {
      try {
        const payload = JSON.parse(body);
        const channel = await getChannel();

        const trunc = (s, n) => s && s.length > n ? s.slice(0, n - 1) + '…' : (s || '');

        if (payload.kind === 'draft' && payload.draftId) {
          const cid = `${payload.draftId}:${payload.account}`;
          const buttons = [
            new ButtonBuilder()
              .setCustomId(`send:${cid}`)
              .setLabel('送信')
              .setStyle(ButtonStyle.Success),
            new ButtonBuilder()
              .setCustomId(`revise:${cid}`)
              .setLabel('改稿')
              .setStyle(ButtonStyle.Primary),
          ];
          if (payload.gmailUrl) {
            buttons.push(
              new ButtonBuilder()
                .setLabel('Gmailで開く')
                .setStyle(ButtonStyle.Link)
                .setURL(payload.gmailUrl),
            );
          }
          const row = new ActionRowBuilder().addComponents(...buttons);
          const embed = new EmbedBuilder()
            .setColor(0x2ecc71)
            .setTitle(trunc(payload.text, 256))
            .addFields(
              { name: '送信者', value: trunc(payload.from || '(不明)', 1024) },
              { name: '受信メール', value: trunc(payload.originalBody || '(本文なし)', 1024) },
              { name: '返信案', value: trunc(payload.draftBody || '(本文なし)', 1024) },
            );
          await channel.send({ embeds: [embed], components: [row] });
          console.log(`[bot] notified draft:${payload.draftId}@${payload.account}`);
        } else if (payload.kind === 'check') {
          const embed = new EmbedBuilder()
            .setColor(0xf39c12)
            .setTitle(trunc(payload.text, 256))
            .addFields(
              { name: '詳細', value: trunc(payload.reason || '(詳細なし)', 1024) },
            );
          const components = [];
          if (payload.gmailUrl) {
            components.push(new ActionRowBuilder().addComponents(
              new ButtonBuilder()
                .setLabel('Gmailで開く')
                .setStyle(ButtonStyle.Link)
                .setURL(payload.gmailUrl),
            ));
          }
          await channel.send({ embeds: [embed], components });
          console.log(`[bot] notified check@${payload.account}`);
        } else if (payload.kind === 'spam') {
          spamCandidates.set(payload.messageId, { from: payload.from, account: payload.account });
          const cid = `${payload.messageId}:${payload.account}`;
          const spamButtons = [
            new ButtonBuilder()
              .setCustomId(`spam-confirm:${cid}`)
              .setLabel('迷惑メールに設定')
              .setStyle(ButtonStyle.Danger),
            new ButtonBuilder()
              .setCustomId(`spam-reject:${cid}`)
              .setLabel('違う（通常メール）')
              .setStyle(ButtonStyle.Secondary),
          ];
          if (payload.gmailUrl) {
            spamButtons.push(
              new ButtonBuilder()
                .setLabel('Gmailで開く')
                .setStyle(ButtonStyle.Link)
                .setURL(payload.gmailUrl),
            );
          }
          const row = new ActionRowBuilder().addComponents(...spamButtons);
          const embed = new EmbedBuilder()
            .setColor(0xe74c3c)
            .setTitle(trunc(payload.text, 256))
            .addFields(
              { name: '送信者', value: trunc(payload.from || '(不明)', 1024) },
              { name: '判断理由', value: trunc(payload.reason || '(理由なし)', 1024) },
            );
          await channel.send({ embeds: [embed], components: [row] });
          console.log(`[bot] notified spam:${payload.messageId}@${payload.account}`);
        } else {
          await channel.send({ content: payload.text });
          console.log(`[bot] notified ${payload.kind || 'unknown'}@${payload.account}`);
        }

        res.writeHead(200);
        res.end('ok');
      } catch (e) {
        console.error('[bot] notify error:', e.message);
        res.writeHead(500);
        res.end(e.message);
      }
    });
  });

  server.listen(PORT, '127.0.0.1', () => {
    console.log(`[bot] HTTP listening on 127.0.0.1:${PORT}`);
  });
}

client.login(TOKEN).catch(e => {
  console.error('[bot] login failed:', e.message);
  process.exit(1);
});
