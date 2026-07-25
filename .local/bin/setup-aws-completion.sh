#!/usr/bin/env bash

# Official AWS CLI v2 installer places aws_completer in /usr/local/bin
if ! [ -x "$(command -v aws_completer)" ]; then
  if [ -x /usr/local/bin/aws_completer ]; then
    echo 'aws_completer is already installed at /usr/local/bin/aws_completer'
  else
    echo 'aws_completer not found. Install AWS CLI v2 first (update-os).' >&2
    exit 1
  fi
fi

# System-wide bash completion for all users
if [ ! -f /etc/bash_completion.d/aws.sh ]; then
  echo 'Installing AWS CLI completion for all users...'
  echo 'complete -C /usr/local/bin/aws_completer aws' | sudo tee /etc/bash_completion.d/aws.sh > /dev/null
fi

echo "AWS CLI completion has been set up!"
