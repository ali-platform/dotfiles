Based on https://www.atlassian.com/git/tutorials/dotfiles

First, follow the instructions for the Window Boxstarter scripts
https://github.com/ali-platform/boxstarter



Open a WSL session and run this batch of commands
```
alias dotfiles='/usr/bin/git --git-dir=$HOME/.cfg/ --work-tree=$HOME'
git config --global credential.helper "/mnt/c/Program\ Files/Git/mingw64/bin/git-credential-manager.exe"
git clone --bare "https://github.com/ali-platform/dotfiles.git" $HOME/.cfg
dotfiles config --local status.showUntrackedFiles no
dotfiles checkout -f main

~/.local/bin/init-os.sh
gh auth login
```

Only Rob should run this.  This is to update the repo.
```
dotfiles push --set-upstream origin main
```

When that is complete, run this batch of commands
```
source ~/.bash_profile
~/.local/bin/init-repos

```
