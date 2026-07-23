#!/bin/bash
# Simpbar Installer
# Optimized for Arch Linux

set -e

echo "Setting up your desktop..."

if ! command -v pacman >/dev/null; then
    echo "This script is Arch-only (pacman not found). Aborting."
    exit 1
fi

# Ensure required tools are present
if ! command -v unzip >/dev/null; then
    echo "unzip not found — installing..."
    sudo pacman -S --noconfirm --needed unzip curl
fi

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

sudo pacman -S --noconfirm --needed gnome-calendar wlogout swaybg ttf-jetbrains-mono-nerd

# waypaper is in AUR — use yay (most common). Fall back to paru if present
if command -v yay >/dev/null; then
    yay -S --noconfirm --needed waypaper
elif command -v paru >/dev/null; then
    paru -S --noconfirm --needed waypaper
else
    echo "No AUR helper (yay/paru) found. Install waypaper manually with: yay -S waypaper"
fi

echo "Setup complete. Restart your session or run:"
echo "   waybar &"
echo "   swaybg -i /path/to/your/wallpaper.jpg -m fill &"  # Example
echo "   waypaper"  # To choose wallpapers
