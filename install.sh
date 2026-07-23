#!/bin/bash
# Simpbar Installer
# Optimized for Arch Linux

set -e

echo "Setting up your desktop..."

# Create config dir
mkdir -p ~/.config

# Download and extract waybar config
echo "Fetching simpbar theme..."
curl -L -o /tmp/simpbar.zip https://github.com/jaytheoutpatient/simpbar/archive/refs/heads/main.zip
unzip -o /tmp/simpbar.zip -d /tmp/simpbar-temp
cp -r /tmp/simpbar-temp/simpbar-main/waybar ~/.config/
rm -rf /tmp/simpbar-temp /tmp/simpbar.zip

echo "Waybar config placed in ~/.config/waybar"

# Install dependencies
echo "Installing gnome-calendar, wlogout, swaybg, waypaper & JetBrainsMono Nerd Font..."

if command -v pacman >/dev/null; then
    echo "Arch Linux detected — installing official packages..."
    sudo pacman -S --noconfirm --needed gnome-calendar wlogout swaybg ttf-jetbrains-mono-nerd

    # waypaper is in AUR — use yay (most common). Fall back to paru if present
    if command -v yay >/dev/null; then
        yay -S --noconfirm --needed waypaper
    elif command -v paru >/dev/null; then
        paru -S --noconfirm --needed waypaper
    else
        echo "No AUR helper (yay/paru) found. Install waypaper manually with: yay -S waypaper"
    fi

elif command -v apt >/dev/null; then
    sudo apt update
    sudo apt install -y gnome-calendar wlogout
    # swaybg & waypaper via other means (or manual)
    echo "Debian/Ubuntu: swaybg and waypaper may need manual install or backports."
    # Nerd font
    mkdir -p ~/.local/share/fonts
    curl -L -o /tmp/JetBrainsMono.zip https://github.com/ryanoasis/nerd-fonts/releases/download/v3.2.1/JetBrainsMono.zip
    unzip -o /tmp/JetBrainsMono.zip -d ~/.local/share/fonts/
    rm /tmp/JetBrainsMono.zip
    fc-cache -fv

elif command -v dnf >/dev/null; then
    sudo dnf install -y gnome-calendar wlogout
    # Similar for others...
    mkdir -p ~/.local/share/fonts
    curl -L -o /tmp/JetBrainsMono.zip https://github.com/ryanoasis/nerd-fonts/releases/download/v3.2.1/JetBrainsMono.zip
    unzip -o /tmp/JetBrainsMono.zip -d ~/.local/share/fonts/
    rm /tmp/JetBrainsMono.zip
    fc-cache -fv
else
    echo "Unknown distro. Install manually: gnome-calendar, wlogout, swaybg, waypaper, and JetBrainsMono Nerd Font."
fi

echo "Setup complete. Restart your session or run:"
echo "   waybar &"
echo "   swaybg -i /path/to/your/wallpaper.jpg -m fill &"  # Example
echo "   waypaper"  # To choose wallpapers
