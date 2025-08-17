#!/usr/bin/env bash

# Create a symbolic link for aws_completer if it doesn't exist
if ! [ -x "$(command -v aws_completer)" ]; then
  echo 'Creating symbolic link for aws_completer...'
  sudo ln -sf /snap/aws-cli/current/bin/aws_completer /usr/local/bin/aws_completer
fi

# Check if completion is already in .bash_profile
if grep -q "complete -C aws_completer aws" ~/.bash_profile; then
  echo "AWS CLI completion is already configured in .bash_profile"
else
  echo "Adding AWS CLI completion to .bash_profile"
  echo "complete -C aws_completer aws" >> ~/.bash_profile
fi

# Source bash_profile to apply changes immediately
source ~/.bash_profile

echo "AWS CLI completion has been set up!"
