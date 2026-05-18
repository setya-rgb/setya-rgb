# zp - Zsh Plugin Manager using yq for YAML parsing
# Requires: yq (https://github.com/mikefarah/yq)

ZP_GLOBAL_DIR="${ZP_GLOBAL_DIR:-$HOME/.zp}"
ZP_GLOBAL_PLUGINS_DIR="${ZP_GLOBAL_PLUGINS_DIR:-$HOME/.zsh/plugins}"
ZP_GLOBAL_CONFIG="${ZP_GLOBAL_CONFIG:-$ZP_GLOBAL_DIR/plugins.yaml}"

# Local config
ZP_LOCAL_CONFIG=""
ZP_LOCAL_PLUGINS_DIR=""

# Colors
autoload -U colors && colors

# Check if yq is installed
zp_check_yq() {
    if ! command -v yq &> /dev/null; then
        print -P "%F{red}Error: yq is required but not installed.%f"
        print -P "%F{yellow}Install it with:%f"
        print "  - macOS: brew install yq"
        print "  - Linux: sudo snap install yq  or  wget https://github.com/mikefarah/yq/releases/..."
        return 1
    fi
    return 0
}

# Initialize directories and config
zp_init() {
    local config_file=$1
    local plugins_dir=$2

    mkdir -p "$plugins_dir"
    mkdir -p "$(dirname "$config_file")"

    # Create default YAML config if missing
    if [[ ! -f "$config_file" ]]; then
        cat > "$config_file" << 'EOF'
# zp YAML plugin configuration
plugins:
  # Examples:
  # - name: zsh-autosuggestions
  #   github: zsh-users/zsh-autosuggestions
  #   branch: master
  #
  # - name: zsh-syntax-highlighting
  #   github: zsh-users/zsh-syntax-highlighting
  #   branch: master
  #
  # - name: powerlevel10k
  #   github: romkatv/powerlevel10k
  #   branch: master
  #   type: theme  # Optional: theme, plugin
EOF
    fi
}

# Parse plugins using yq
zp_parse_plugins() {
    local config_file=$1
    
    if [[ ! -f "$config_file" ]]; then
        return
    fi
    
    # Use yq to extract plugin information
    # Format: name|github|branch|type
    yq eval '.plugins[] | [.name, .github, .branch // "master", .type // "plugin"] | join("|")' "$config_file" 2>/dev/null
}

# Clone or update plugin
zp_clone() {
    local name=$1
    local github_path=$2
    local branch=$3
    local plugins_dir=$4
    local url="https://github.com/${github_path}.git"
    local plugin_path="$plugins_dir/$name"

    if [[ -d "$plugin_path" ]]; then
        # Update existing plugin
        (cd "$plugin_path" && git pull --quiet origin "$branch" &>/dev/null)
        return 0
    else
        # Clone new plugin
        git clone --quiet --depth 1 --branch "$branch" "$url" "$plugin_path" &>/dev/null
        return $?
    fi
}

# Load plugins
zp_load() {
    local local_mode=$1
    
    zp_check_yq || return 1

    if [[ "$local_mode" == "local" ]]; then
        zp_load_local
    else
        zp_load_global
        zp_load_local
    fi
}

zp_load_global() {
    print -P "%F{blue}→ Loading global plugins from $ZP_GLOBAL_CONFIG%f"
    
    # Check if config exists
    if [[ ! -f "$ZP_GLOBAL_CONFIG" ]]; then
        print -P "%F{yellow}⚠ No global config found. Run 'zp init' first.%f"
        return 1
    fi
    
    # Check if there are any plugins
    local plugin_count=$(yq eval '.plugins | length' "$ZP_GLOBAL_CONFIG" 2>/dev/null)
    if [[ -z "$plugin_count" || "$plugin_count" -eq 0 ]]; then
        print -P "%F{yellow}⚠ No plugins defined in config%f"
        return 0
    fi
    
    local pids=()
    
    # Clone/update plugins in parallel
    while IFS='|' read -r name github branch type; do
        if [[ -n "$name" && -n "$github" ]]; then
            print -P "%F{green}  ✓%f $name ($branch) [${type:-plugin}] [global]"
            zp_clone "$name" "$github" "$branch" "$ZP_GLOBAL_PLUGINS_DIR" &
            pids+=($!)
        fi
    done <<< "$(zp_parse_plugins "$ZP_GLOBAL_CONFIG")"
    
    # Wait for all clones to finish
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    
    # Source plugins in order
    while IFS='|' read -r name github branch type; do
        if [[ -n "$name" ]]; then
            zp_source_plugin "$name" "$ZP_GLOBAL_PLUGINS_DIR" "global" "$type"
        fi
    done <<< "$(zp_parse_plugins "$ZP_GLOBAL_CONFIG")"
}

zp_load_local() {
    # Find local .zp config in current or parent directories
    local current_dir="$PWD"
    local found_config=""
    
    while [[ "$current_dir" != "/" ]]; do
        if [[ -f "$current_dir/.zp/plugins.yaml" ]]; then
            found_config="$current_dir/.zp/plugins.yaml"
            ZP_LOCAL_PLUGINS_DIR="$current_dir/.zp/plugins"
            break
        fi
        current_dir="$(dirname "$current_dir")"
    done
    
    if [[ -n "$found_config" ]]; then
        ZP_LOCAL_CONFIG="$found_config"
        mkdir -p "$ZP_LOCAL_PLUGINS_DIR"
        
        print -P "%F{blue}→ Loading local plugins from $ZP_LOCAL_CONFIG%f"
        
        local plugin_count=$(yq eval '.plugins | length' "$ZP_LOCAL_CONFIG" 2>/dev/null)
        if [[ -z "$plugin_count" || "$plugin_count" -eq 0 ]]; then
            print -P "%F{yellow}⚠ No local plugins defined%f"
            return 0
        fi
        
        local pids=()
        
        # Clone/update plugins in parallel
        while IFS='|' read -r name github branch type; do
            if [[ -n "$name" && -n "$github" ]]; then
                print -P "%F{cyan}  📁%f $name ($branch) [${type:-plugin}] [local]"
                zp_clone "$name" "$github" "$branch" "$ZP_LOCAL_PLUGINS_DIR" &
                pids+=($!)
            fi
        done <<< "$(zp_parse_plugins "$ZP_LOCAL_CONFIG")"
        
        # Wait for all clones to finish
        for pid in "${pids[@]}"; do
            wait "$pid"
        done
        
        # Source local plugins
        while IFS='|' read -r name github branch type; do
            if [[ -n "$name" ]]; then
                zp_source_plugin "$name" "$ZP_LOCAL_PLUGINS_DIR" "local" "$type"
            fi
        done <<< "$(zp_parse_plugins "$ZP_LOCAL_CONFIG")"
        
    elif [[ "$1" == "strict" ]]; then
        print -P "%F{red}⚠ No local .zp/plugins.yaml found in current directory tree%f"
        return 1
    fi
}

zp_source_plugin() {
    local name=$1
    local plugins_dir=$2
    local scope=$3
    local type=$4
    local plugin_path="$plugins_dir/$name"
    
    # For themes, source differently
    if [[ "$type" == "theme" ]]; then
        if [[ -f "$plugin_path/$name.zsh-theme" ]]; then
            source "$plugin_path/$name.zsh-theme"
            print -P "%F{green}  ✓%f Sourced $name [$scope] (theme)"
        elif [[ -f "$plugin_path/$name.theme.zsh" ]]; then
            source "$plugin_path/$name.theme.zsh"
            print -P "%F{green}  ✓%f Sourced $name [$scope] (theme)"
        else
            print -P "%F{yellow}  ⚠%f $name [$scope] (no theme file found)"
        fi
        return
    fi
    
    # Source plugin files in priority order
    if [[ -f "$plugin_path/$name.plugin.zsh" ]]; then
        source "$plugin_path/$name.plugin.zsh"
        print -P "%F{green}  ✓%f Sourced $name [$scope]"
    elif [[ -f "$plugin_path/$name.zsh" ]]; then
        source "$plugin_path/$name.zsh"
        print -P "%F{green}  ✓%f Sourced $name [$scope]"
    elif [[ -f "$plugin_path/init.zsh" ]]; then
        source "$plugin_path/init.zsh"
        print -P "%F{green}  ✓%f Sourced $name [$scope]"
    else
        # Add to fpath for completion files
        if [[ -d "$plugin_path" ]]; then
            fpath+=("$plugin_path")
            print -P "%F{green}  ✓%f Added $name to fpath [$scope]"
        else
            print -P "%F{yellow}  ⚠%f $name [$scope] (no init file found)"
        fi
    fi
}

# List plugins with more details
zp_list() {
    print -P "%F{blue}Global plugins:%f"
    if [[ -f "$ZP_GLOBAL_CONFIG" ]]; then
        # Use yq to get list of plugins
        local plugins=$(yq eval '.plugins[].name' "$ZP_GLOBAL_CONFIG" 2>/dev/null)
        if [[ -n "$plugins" ]]; then
            while IFS= read -r name; do
                if [[ -n "$name" ]]; then
                    local branch=$(yq eval ".plugins[] | select(.name == \"$name\") | .branch // \"master\"" "$ZP_GLOBAL_CONFIG" 2>/dev/null)
                    local type=$(yq eval ".plugins[] | select(.name == \"$name\") | .type // \"plugin\"" "$ZP_GLOBAL_CONFIG" 2>/dev/null)
                    local github=$(yq eval ".plugins[] | select(.name == \"$name\") | .github" "$ZP_GLOBAL_CONFIG" 2>/dev/null)
                    
                    if [[ -d "$ZP_GLOBAL_PLUGINS_DIR/$name" ]]; then
                        print -P "  - %F{cyan}$name%f (%F{yellow}$branch%f) [${type}] - $github"
                    else
                        print -P "  - %F{red}$name%f (%F{yellow}$branch%f) [${type}] - NOT INSTALLED"
                    fi
                fi
            done <<< "$plugins"
        else
            print -P "  %F{yellow}No plugins configured%f"
        fi
    else
        print -P "  %F{red}No global config found. Run 'zp init'%f"
    fi
    
    # Check for local plugins
    local current_dir="$PWD"
    while [[ "$current_dir" != "/" ]]; do
        if [[ -f "$current_dir/.zp/plugins.yaml" ]]; then
            print -P "\n%F{blue}Local plugins (in $current_dir):%f"
            local plugins=$(yq eval '.plugins[].name' "$current_dir/.zp/plugins.yaml" 2>/dev/null)
            if [[ -n "$plugins" ]]; then
                while IFS= read -r name; do
                    if [[ -n "$name" ]]; then
                        local branch=$(yq eval ".plugins[] | select(.name == \"$name\") | .branch // \"master\"" "$current_dir/.zp/plugins.yaml" 2>/dev/null)
                        local type=$(yq eval ".plugins[] | select(.name == \"$name\") | .type // \"plugin\"" "$current_dir/.zp/plugins.yaml" 2>/dev/null)
                        local github=$(yq eval ".plugins[] | select(.name == \"$name\") | .github" "$current_dir/.zp/plugins.yaml" 2>/dev/null)
                        
                        if [[ -d "$current_dir/.zp/plugins/$name" ]]; then
                            print -P "  - %F{cyan}$name%f (%F{yellow}$branch%f) [${type}] - $github [local]"
                        else
                            print -P "  - %F{red}$name%f (%F{yellow}$branch%f) [${type}] - NOT INSTALLED [local]"
                        fi
                    fi
                done <<< "$plugins"
            fi
            break
        fi
        current_dir="$(dirname "$current_dir")"
    done
}

# Update plugins
zp_update() {
    zp_check_yq || return 1
    
    # Update global plugins
    print -P "%F{yellow}→ Updating global plugins...%f"
    if [[ -f "$ZP_GLOBAL_CONFIG" ]]; then
        while IFS='|' read -r name github branch type; do
            if [[ -n "$name" ]]; then
                local plugin_path="$ZP_GLOBAL_PLUGINS_DIR/$name"
                if [[ -d "$plugin_path" ]]; then
                    print -P "%F{green}  ✓%f Updating $name [global]"
                    (cd "$plugin_path" && git pull --quiet origin "$branch")
                fi
            fi
        done <<< "$(zp_parse_plugins "$ZP_GLOBAL_CONFIG")"
    fi
    
    # Update local plugins if present
    local current_dir="$PWD"
    while [[ "$current_dir" != "/" ]]; do
        local local_config="$current_dir/.zp/plugins.yaml"
        if [[ -f "$local_config" ]]; then
            print -P "\n%F{yellow}→ Updating local plugins in $current_dir...%f"
            while IFS='|' read -r name github branch type; do
                if [[ -n "$name" ]]; then
                    local plugin_path="$current_dir/.zp/plugins/$name"
                    if [[ -d "$plugin_path" ]]; then
                        print -P "%F{cyan}  📁%f Updating $name [local]"
                        (cd "$plugin_path" && git pull --quiet origin "$branch")
                    fi
                fi
            done <<< "$(zp_parse_plugins "$local_config")"
            break
        fi
        current_dir="$(dirname "$current_dir")"
    done
    
    print -P "%F{green}✓ Update complete!%f"
}

# Add plugin using yq
zp_add() {
    local local_flag=0
    local name=""
    local github=""
    local branch="master"
    local type="plugin"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --local)
                local_flag=1
                shift
                ;;
            --theme)
                type="theme"
                shift
                ;;
            --plugin)
                type="plugin"
                shift
                ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                elif [[ -z "$github" ]]; then
                    github="$1"
                else
                    branch="$1"
                fi
                shift
                ;;
        esac
    done
    
    if [[ -z "$name" || -z "$github" ]]; then
        print -P "%F{red}Usage: zp add [--local] [--theme|--plugin] <name> <github-user/repo> [branch]%f"
        return 1
    fi
    
    if [[ $local_flag -eq 1 ]]; then
        # Add to local config
        local local_config="./.zp/plugins.yaml"
        mkdir -p "./.zp"
        
        if [[ ! -f "$local_config" ]]; then
            echo "plugins:" > "$local_config"
        fi
        
        # Use yq to add plugin
        local temp_file=$(mktemp)
        yq eval ".plugins += [{\"name\": \"$name\", \"github\": \"$github\", \"branch\": \"$branch\", \"type\": \"$type\"}]" "$local_config" > "$temp_file"
        mv "$temp_file" "$local_config"
        
        print -P "%F{green}✓ Added $name ($github) as $type to local config%f"
        print -P "%F{yellow}Run 'zp load --local' to install it%f"
    else
        # Add to global config
        if [[ ! -f "$ZP_GLOBAL_CONFIG" ]]; then
            echo "plugins:" > "$ZP_GLOBAL_CONFIG"
        fi
        
        local temp_file=$(mktemp)
        yq eval ".plugins += [{\"name\": \"$name\", \"github\": \"$github\", \"branch\": \"$branch\", \"type\": \"$type\"}]" "$ZP_GLOBAL_CONFIG" > "$temp_file"
        mv "$temp_file" "$ZP_GLOBAL_CONFIG"
        
        print -P "%F{green}✓ Added $name ($github) as $type to global config%f"
        print -P "%F{yellow}Run 'zp load' to install it%f"
    fi
}

# Remove plugin using yq
zp_remove() {
    local local_flag=0
    local name=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --local)
                local_flag=1
                shift
                ;;
            *)
                name="$1"
                shift
                ;;
        esac
    done
    
    if [[ -z "$name" ]]; then
        print -P "%F{red}Usage: zp remove [--local] <name>%f"
        return 1
    fi
    
    if [[ $local_flag -eq 1 ]]; then
        # Remove from local config
        if [[ -f "./.zp/plugins.yaml" ]]; then
            local temp_file=$(mktemp)
            yq eval "del(.plugins[] | select(.name == \"$name\"))" "./.zp/plugins.yaml" > "$temp_file"
            mv "$temp_file" "./.zp/plugins.yaml"
            rm -rf "./.zp/plugins/$name"
            print -P "%F{green}✓ Removed $name from local config%f"
        else
            print -P "%F{red}No local config found%f"
        fi
    else
        # Remove from global config
        if [[ -f "$ZP_GLOBAL_CONFIG" ]]; then
            local temp_file=$(mktemp)
            yq eval "del(.plugins[] | select(.name == \"$name\"))" "$ZP_GLOBAL_CONFIG" > "$temp_file"
            mv "$temp_file" "$ZP_GLOBAL_CONFIG"
            rm -rf "$ZP_GLOBAL_PLUGINS_DIR/$name"
            print -P "%F{green}✓ Removed $name from global config%f"
        else
            print -P "%F{red}No global config found%f"
        fi
    fi
}

# Show plugin info
zp_info() {
    local name=$1
    local local_flag=0
    
    if [[ "$name" == "--local" ]]; then
        local_flag=1
        name=$2
    fi
    
    if [[ -z "$name" ]]; then
        print -P "%F{red}Usage: zp info [--local] <name>%f"
        return 1
    fi
    
    if [[ $local_flag -eq 1 ]]; then
        local config="./.zp/plugins.yaml"
        if [[ ! -f "$config" ]]; then
            print -P "%F{red}No local config found%f"
            return 1
        fi
        print -P "%F{blue}Local plugin info: $name%f"
    else
        local config="$ZP_GLOBAL_CONFIG"
        if [[ ! -f "$config" ]]; then
            print -P "%F{red}No global config found%f"
            return 1
        fi
        print -P "%F{blue}Global plugin info: $name%f"
    fi
    
    # Extract plugin info using yq
    local github=$(yq eval ".plugins[] | select(.name == \"$name\") | .github" "$config")
    local branch=$(yq eval ".plugins[] | select(.name == \"$name\") | .branch // \"master\"" "$config")
    local type=$(yq eval ".plugins[] | select(.name == \"$name\") | .type // \"plugin\"" "$config")
    
    if [[ -n "$github" ]]; then
        print -P "  Name:   %F{cyan}$name%f"
        print -P "  Repo:   %F{green}$github%f"
        print -P "  Branch: %F{yellow}$branch%f"
        print -P "  Type:   %F{magenta}$type%f"
        print -P "  URL:    https://github.com/$github"
    else
        print -P "%F{red}Plugin '$name' not found%f"
    fi
}

# Initialize local config
zp_init_local() {
    if [[ -f "./.zp/plugins.yaml" ]]; then
        print -P "%F{yellow}Local config already exists%f"
        return 1
    fi
    
    mkdir -p "./.zp"
    cat > "./.zp/plugins.yaml" << 'EOF'
# Local project-specific plugins
plugins:
  # Add project-specific plugins here
  # - name: my-project-plugin
  #   github: myuser/myproject-plugin
  #   branch: main
  #   type: plugin
EOF
    
    print -P "%F{green}✓ Initialized local config in .zp/plugins.yaml%f"
}

# Clean up unused plugin directories
zp_clean() {
    local local_flag=0
    
    if [[ "$1" == "--local" ]]; then
        local_flag=1
    fi
    
    if [[ $local_flag -eq 1 ]]; then
        if [[ -d "./.zp/plugins" ]]; then
            print -P "%F{yellow}→ Checking local plugins...%f"
            local config="./.zp/plugins.yaml"
            if [[ -f "$config" ]]; then
                local plugins=$(yq eval '.plugins[].name' "$config")
                for plugin in "./.zp/plugins"/*; do
                    if [[ -d "$plugin" ]]; then
                        local name=$(basename "$plugin")
                        if [[ ! " $plugins " =~ " $name " ]]; then
                            print -P "%F{red}  Removing orphaned plugin: $name%f"
                            rm -rf "$plugin"
                        fi
                    fi
                done
            fi
        fi
    else
        if [[ -d "$ZP_GLOBAL_PLUGINS_DIR" ]]; then
            print -P "%F{yellow}→ Checking global plugins...%f"
            if [[ -f "$ZP_GLOBAL_CONFIG" ]]; then
                local plugins=$(yq eval '.plugins[].name' "$ZP_GLOBAL_CONFIG")
                for plugin in "$ZP_GLOBAL_PLUGINS_DIR"/*; do
                    if [[ -d "$plugin" ]]; then
                        local name=$(basename "$plugin")
                        if [[ ! " $plugins " =~ " $name " ]]; then
                            print -P "%F{red}  Removing orphaned plugin: $name%f"
                            rm -rf "$plugin"
                        fi
                    fi
                done
            fi
        fi
    fi
    
    print -P "%F{green}✓ Cleanup complete%f"
}

# Export plugins to a file
zp_export() {
    local output_file="${1:-zp-plugins.yaml}"
    
    if [[ -f "$ZP_GLOBAL_CONFIG" ]]; then
        cp "$ZP_GLOBAL_CONFIG" "$output_file"
        print -P "%F{green}✓ Exported global plugins to $output_file%f"
    else
        print -P "%F{red}No global config found%f"
        return 1
    fi
}

# Main CLI
zp() {
    case "$1" in
        init)
            if [[ "$2" == "--local" ]]; then
                zp_init_local
            else
                zp_init "$ZP_GLOBAL_CONFIG" "$ZP_GLOBAL_PLUGINS_DIR"
                print -P "%F{green}✓ Initialized global config! Edit $ZP_GLOBAL_CONFIG%f"
            fi
            ;;
        load)
            if [[ "$2" == "--local" ]]; then
                zp_load "local"
            else
                zp_init "$ZP_GLOBAL_CONFIG" "$ZP_GLOBAL_PLUGINS_DIR" 2>/dev/null
                zp_load "global+local"
            fi
            ;;
        list)
            zp_list
            ;;
        update)
            zp_update
            ;;
        add)
            shift
            zp_add "$@"
            ;;
        remove|rm)
            shift
            zp_remove "$@"
            ;;
        info)
            shift
            zp_info "$@"
            ;;
        clean)
            shift
            zp_clean "$@"
            ;;
        export)
            shift
            zp_export "$@"
            ;;
        help|--help|-h)
            print -P "%F{cyan}zp - Zsh Plugin Manager with yq support%f"
            print -P "%F{blue}Commands:%f"
            print "  zp init                   - Initialize global config"
            print "  zp init --local           - Initialize local config in current dir"
            print "  zp load                   - Load global + local plugins"
            print "  zp load --local           - Load only local plugins"
            print "  zp list                   - List all plugins with details"
            print "  zp update                 - Update all plugins"
            print "  zp add <name> <repo> [branch]     - Add global plugin"
            print "  zp add --theme <name> <repo>      - Add theme"
            print "  zp add --local <name> <repo>      - Add local plugin"
            print "  zp remove <name>          - Remove global plugin"
            print "  zp remove --local <name>  - Remove local plugin"
            print "  zp info <name>            - Show plugin details"
            print "  zp clean                  - Remove orphaned plugin directories"
            print "  zp export [file]          - Export config to file"
            ;;
        *)
            print -P "%F{red}Unknown command: $1%f"
            print -P "Run 'zp help' for usage"
            return 1
            ;;
    esac
}

# Auto-load if sourced directly
if [[ "${(%):-%N}" == *"zp"* ]]; then
    zp load
fi