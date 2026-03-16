#!/bin/sh
set -e

CONFIG_PATH="${ODOOCLAW_CONFIG:-${HOME}/.odooclaw/config.json}"

# First-run: neither config nor workspace exists.
# If config.json is already mounted but workspace is missing we skip onboard to
# avoid the interactive "Overwrite? (y/n)" prompt hanging in a non-TTY container.
if [ ! -d "${HOME}/.odooclaw/workspace" ] && [ ! -f "$CONFIG_PATH" ]; then
    odooclaw onboard
    echo ""
    echo "First-run setup complete."
    echo "Edit $CONFIG_PATH (add your API key, etc.) then restart the container."
    exit 0
fi

# Inject provider API keys into model_list at startup.
# This ensures env vars like ODOOCLAW_PROVIDERS_GROQ_API_KEY are applied to
# model_list entries even when the config file has no api_key set.
python3 - << 'PYEOF'
import json, os, sys

config_path = os.environ.get('ODOOCLAW_CONFIG', os.path.expanduser('~/.odooclaw/config.json'))

# Map of env var -> (protocol_prefix, api_base)
providers = {
    'ODOOCLAW_PROVIDERS_GROQ_API_KEY':      ('groq/',      'https://api.groq.com/openai/v1'),
    'ODOOCLAW_PROVIDERS_ANTHROPIC_API_KEY': ('anthropic/',  'https://api.anthropic.com'),
    'ODOOCLAW_PROVIDERS_OPENAI_API_KEY':    ('openai/',     'https://api.openai.com/v1'),
    'ODOOCLAW_PROVIDERS_DEEPSEEK_API_KEY':  ('deepseek/',   'https://api.deepseek.com/v1'),
    'ODOOCLAW_PROVIDERS_GEMINI_API_KEY':    ('gemini/',     ''),
    'ODOOCLAW_PROVIDERS_OPENROUTER_API_KEY':('openrouter/', 'https://openrouter.ai/api/v1'),
    'ODOOCLAW_PROVIDERS_MISTRAL_API_KEY':   ('mistral/',    'https://api.mistral.ai/v1'),
    'ODOOCLAW_PROVIDERS_CEREBRAS_API_KEY':  ('cerebras/',   'https://api.cerebras.ai/v1'),
}

try:
    with open(config_path) as f:
        cfg = json.load(f)
except Exception as e:
    print(f'[entrypoint] Could not read config: {e}', flush=True)
    sys.exit(0)

model_list = cfg.get('model_list', [])
changed = False

for env_key, (protocol, default_base) in providers.items():
    api_key = os.environ.get(env_key, '')
    if not api_key:
        continue

    # Inject into existing model_list entries that use this protocol
    for entry in model_list:
        if entry.get('model', '').startswith(protocol) and not entry.get('api_key'):
            entry['api_key'] = api_key
            changed = True

    # If the user's configured model uses this provider and isn't in the list, add it
    model_name = os.environ.get('ODOOCLAW_AGENTS_DEFAULTS_MODEL_NAME', '')
    provider_name = os.environ.get('ODOOCLAW_AGENTS_DEFAULTS_PROVIDER', '')
    proto_name = protocol.rstrip('/')

    if model_name and provider_name == proto_name:
        existing = [e for e in model_list if e.get('model_name') == model_name]
        if not existing:
            entry = {
                'model_name': model_name,
                'model': f'{protocol}{model_name}',
                'api_key': api_key,
            }
            if default_base:
                entry['api_base'] = default_base
            model_list.append(entry)
            changed = True
            print(f'[entrypoint] Added model_list entry: {model_name}', flush=True)
        else:
            for e in existing:
                if not e.get('api_key'):
                    e['api_key'] = api_key
                    changed = True

# Ensure MCP odoo-manager is configured (may be missing from old onboard-generated configs)
tools = cfg.setdefault('tools', {})
mcp = tools.setdefault('mcp', {})
if not mcp.get('enabled'):
    mcp['enabled'] = True
    changed = True
servers = mcp.setdefault('servers', {})
if 'odoo-manager' not in servers:
    servers['odoo-manager'] = {
        'enabled': True,
        'command': 'python3',
        'args': ['/usr/local/bin/odoo-mcp.py'],
    }
    changed = True
    print('[entrypoint] Injected MCP odoo-manager config', flush=True)

if changed:
    cfg['model_list'] = model_list
    # Write only if not read-only
    try:
        with open(config_path, 'w') as f:
            json.dump(cfg, f, indent=2)
        print(f'[entrypoint] Config updated with provider API keys', flush=True)
    except OSError as e:
        # Config may be mounted read-only; that's OK if code-level injection works
        print(f'[entrypoint] Config is read-only ({e}), relying on runtime injection', flush=True)
PYEOF

# Seed workspace files from image to volume
WORKSPACE_DIR="${HOME}/.odooclaw/workspace"
DEFAULT_WORKSPACE="/tmp/odooclaw-default-workspace"

if [ -d "$DEFAULT_WORKSPACE" ]; then
    # Seed top-level files (AGENTS.md, SOUL.md, etc.) — skip if exist
    for f in "$DEFAULT_WORKSPACE"/*.md; do
        [ -f "$f" ] || continue
        dest="$WORKSPACE_DIR/$(basename "$f")"
        if [ ! -f "$dest" ]; then
            mkdir -p "$WORKSPACE_DIR"
            cp "$f" "$dest"
            echo "[entrypoint] Seeded $(basename $f) to workspace"
        fi
    done

    # Seed skills — always update SKILL.md (versioned with code), skip server.py if exists
    if [ -d "$DEFAULT_WORKSPACE/skills" ]; then
        for skill_dir in "$DEFAULT_WORKSPACE/skills"/*/; do
            skill_name=$(basename "$skill_dir")
            dest_dir="$WORKSPACE_DIR/skills/$skill_name"
            mkdir -p "$dest_dir"
            # Always update SKILL.md (instructions are versioned)
            if [ -f "$skill_dir/SKILL.md" ]; then
                cp "$skill_dir/SKILL.md" "$dest_dir/SKILL.md"
            fi
            # Seed other files/dirs only if missing
            for f in "$skill_dir"*; do
                fname=$(basename "$f")
                [ "$fname" = "SKILL.md" ] && continue
                [ -e "$dest_dir/$fname" ] && continue
                cp -r "$f" "$dest_dir/$fname"
            done
        done
        echo "[entrypoint] Workspace skills seeded"
    fi
fi

exec odooclaw "$@"
