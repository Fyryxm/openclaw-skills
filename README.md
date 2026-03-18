# OpenClaw Skills

Custom agent skills for OpenClaw.

## Skills

### model-disaster-recovery

Automatic failover from cloud models to local models when cloud is unavailable.

- Detects cloud model availability (30s timeout)
- Switches to lightweight local model (qwen2.5-7b-dr)
- Auto-recovers when cloud is back
- Integrates with cron for automatic monitoring

**Install:**
```bash
openclaw skills install https://github.com/Fyryxm/openclaw-skills/raw/main/model-disaster-recovery.skill
```

## Usage

1. Download the `.skill` file
2. Install: `openclaw skills install <path-to-skill>`
3. The skill will be available in your OpenClaw agent