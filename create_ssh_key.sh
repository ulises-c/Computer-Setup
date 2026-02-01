EMAIL=""
KEY_NAME=""
GIT_HOST=""

# Create SSH key
ssh-keygen -t ed25519 -b 4096 -C $EMAIL -f ~/.ssh/$KEY_NAME

# Add SSH key to the ssh-agent
eval "$(ssh-agent)"
ssh-add ~/.ssh/$KEY_NAME

# Add SSH key to config file
touch -a ~/.ssh/config # -a
echo "
Host $GIT_HOST
  AddKeysToAgent yes
  IdentityFile ~/.ssh/$KEY_NAME
" >> ~/.ssh/config

# Display public key
echo "Public key:"
cat ~/.ssh/$KEY_NAME.pub
echo ""
echo "Copy the above public key and add it to your $GIT_HOST account."
# pause
read -p "Press [Enter] key after adding the SSH key to your account"

# Test SSH connection
ssh -vT git@$GIT_HOST