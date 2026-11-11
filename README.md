Based on https://www.atlassian.com/git/tutorials/dotfiles

First, follow the instructions for the Window Boxstarter scripts
https://github.com/ali-platform/boxstarter



Open a WSL session and run this batch of commands
```
sudo DEBIAN_FRONTEND=noninteractive apt-get --assume-yes install socat

mkdir -p ~/.ssh
chmod 700 ~/.ssh
ln -sf "$USERPROFILE/.ssh/config" "$HOME/.ssh/config"
ln -sf "$USERPROFILE/.ssh/id_ed25519" "$HOME/.ssh/id_ed25519"
ln -sf "$USERPROFILE/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ed25519.pub"
ssh-keyscan github.com >> ~/.ssh/known_hosts
chmod 600 ~/.ssh/known_hosts

export SSH_AUTH_SOCK=$HOME/.ssh/agent.sock
rm -f $SSH_AUTH_SOCK
( setsid socat UNIX-LISTEN:${SSH_AUTH_SOCK},fork EXEC:"npiperelay.exe -ei -s //./pipe/openssh-ssh-agent",nofork & ) >/dev/null 2>&1

alias dotfiles='/usr/bin/git --git-dir=$HOME/.cfg/ --work-tree=$HOME'
git clone --bare "https://github.com/ali-platform/dotfiles.git" $HOME/.cfg
dotfiles config --local status.showUntrackedFiles no
dotfiles checkout -f main

~/.local/bin/init-os.sh
gh auth login --scopes admin:enterprise,admin:org,admin:org_hook,admin:repo_hook,repo,workflow,write:packages,user:email
```

[`init-os.sh`](./.local/bin/init-os.sh) sets `autoMemoryReclaim=gradual` under
`[experimental]` in the Windows `%UserProfile%\.wslconfig` file. WSL then
reclaims cached memory gradually. The script keeps all other settings.

The `wsl --shutdown` command stops all WSL distributions.
To apply the setting after installation:

1. Save your work in all WSL distributions.
2. Run `wsl --shutdown` from Windows PowerShell.
3. Reopen WSL.

Only Rob should run this.  This is to update the repo.
```
dotfiles push --set-upstream origin main
```

When that is complete, run this batch of commands
```
source ~/.bash_profile
~/.local/bin/init-repos

```
