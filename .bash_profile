# .bash_profile
# Get the aliases and functions
if [ -f ~/.bashrc ]; then
        . ~/.bashrc
fi

# User specific environment and startup programs
export PATH="$HOME/.local/bin:$HOME/.pulumi/bin:/snap/bin:./node_modules/.bin:$PATH"
export KUBECONFIG=$HOME/.kube/config

export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1
export KUBERNETES_EXEC_INFO='{"apiVersion": "client.authentication.k8s.io/v1beta1"}'
export NODE_OPTIONS="--max-old-space-size=8192"
export NODE_NO_WARNINGS=1
export NODE_AUTH_TOKEN=$(gh auth token)
export ALI_GITHUB_PACKAGE_READER_TOKEN=$NODE_AUTH_TOKEN
export NPM_AUTH_TOKEN=$NODE_AUTH_TOKEN
export AWS_PROFILE=ali-shared
export ARM_USE_CLI=true
export NX_TUI=false

# --- SSH agent bridge to Windows OpenSSH (npiperelay + socat) ---
# Exported here unconditionally for ALL login shells, including the
# non-interactive login shell VS Code uses to resolve its Git/extension
# environment. .bashrc only sets this for interactive shells (it returns early
# for non-interactive ones), so without this the VS Code Source Control UI has
# no SSH_AUTH_SOCK and falls back to prompting for the key passphrase / failing
# with "Permission denied (publickey)". The bridge process is (re)started by
# .bashrc for terminals; here we only restart it if the agent is unreachable.
export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"
if command -v socat >/dev/null 2>&1; then
  ssh-add -l >/dev/null 2>&1
  if [ $? -eq 2 ]; then
    pkill -f "socat.*$(basename "$SSH_AUTH_SOCK")" >/dev/null 2>&1
    rm -f "$SSH_AUTH_SOCK"
    ( setsid socat UNIX-LISTEN:"$SSH_AUTH_SOCK",fork EXEC:"npiperelay.exe -ei -s //./pipe/openssh-ssh-agent",nofork & ) >/dev/null 2>&1
  fi
fi

if [[ -n $PS1 ]]; then
  # This causes an issue when oh-my-posh is installed with brew since the installation location changes
  # So do it all manually
  eval "$(oh-my-posh init bash --config ~/.config/oh-my-posh/my-posh.json --strict)"

  # export POSH_THEME="$HOME/.config/oh-my-posh/my-posh.json"
  # export POWERLINE_COMMAND="oh-my-posh"
  # export CONDA_PROMPT_MODIFIER=false

  # # set secondary prompt
  # PS2="$(oh-my-posh print secondary --config="$POSH_THEME" --shell=bash --shell-version="$BASH_VERSION")"

  # function _omp_hook() {
  #     local ret=$?

  #     omp_stack_count=$((${#DIRSTACK[@]} - 1))
  #     omp_elapsed=-1
  #     PS1="$(oh-my-posh print primary --config="$POSH_THEME" --shell=bash --shell-version="$BASH_VERSION" --error="$ret" --execution-time="$omp_elapsed" --stack-count="$omp_stack_count" | tr -d '\0')"

  #     return $ret
  # }

  # if [ "$TERM" != "linux" ] && [ -x "$(command -v oh-my-posh)" ] && ! [[ "$PROMPT_COMMAND" =~ "_omp_hook" ]]; then
  #     PROMPT_COMMAND="_omp_hook; $PROMPT_COMMAND"
  # fi

  # eval "$(oh-my-posh init bash --config ~/.config/oh-my-posh/my-posh.json)"
fi

# Use bash-completion, if available
[[ $PS1 && -f /usr/share/bash-completion/bash_completion ]] && source /usr/share/bash-completion/bash_completion
[[ $PS1 && -f /usr/share/bash-completion/completions/git ]] && source /usr/share/bash-completion/completions/git
complete -F __start_kubectl k
complete -C aws_completer aws

# Configure nvm
# export NVM_DIR="$HOME/.nvm"
# [ -s "/home/linuxbrew/.linuxbrew/opt/nvm/nvm.sh" ] && \. "/home/linuxbrew/.linuxbrew/opt/nvm/nvm.sh"  # This loads nvm
# [ -s "/home/linuxbrew/.linuxbrew/opt/nvm/etc/bash_completion.d/nvm" ] && \. "/home/linuxbrew/.linuxbrew/opt/nvm/etc/bash_completion.d/nvm"  # This loads nvm bash_completion
