# Docker Volume Dirty Backup & Restore (DVDBR)

<p align="left">
  <img src="https://raw.githubusercontent.com/RipleyBooya/DVDBR/refs/heads/main/DVDBR.webp" alt="SSH Tunnel Logo" width="200"/>
</p>

## 🚀 Quick Start

```bash
chmod +x DVDBR.sh
./DVDBR.sh
```

Follow the interactive prompts to configure your backup process.

## ❓ Why This Script?

DVDBR provides a **simple yet flexible** way to backup Docker volumes, whether locally or remotely, ensuring data integrity without unnecessary complexity.

### 🔹 Use Cases
- **Migrating containers between hosts**
- **Regular backups of critical Docker volumes**
- **Disaster recovery preparedness**
- **Offloading backups to remote storage (NAS, cloud, etc.)**

## 🔧 Prerequisites

- **Linux-based system** (Ubuntu, Debian, CentOS, etc.)
- **Docker installed** (`docker` command available)
- **User must be in the `docker` group** (or provide `sudo` access)
- **For remote backups:**
  - `ssh` access to the remote machine
  - `rsync` and `scp` installed

## 🛠 How to Use?

1. **Run the script:**  
   ```bash
   ./DVDBR.sh
   ```
2. **Follow the prompts to:**  
   - Select Docker volumes to back up  
   - Choose between local and/or remote backup  
   - Decide whether to stop running containers  
   - Configure SSH settings for remote backup  
3. **Confirm the backup process** and let DVDBR handle the rest!

## ⚙️ Explanation of Features & Options

- **Backup Modes:**
  - Local backup (stored in a directory of your choice)
  - Remote backup via SSH (`ssh cat`, `rsync`, `scp` fallback)
- **Container Management:**
  - Detects running containers using selected volumes
  - Offers to stop/restart containers before/after backup
- **Filename Customization:**
  - Option to include a timestamp in the backup filename
- **Failover Mechanism:**
  - Uses `ssh cat` by default for remote transfers
  - Falls back to `rsync` and `scp` if needed
- **Logging:**
  - Creates detailed logs with timestamps for troubleshooting

## 🏷️ Tags & Keywords

`docker` `backup` `restore` `volumes` `automation` `shell script` `rsync` `scp` `ssh cat` `container management`

## 📚 Third-Party Licenses

This script utilizes:
- [Docker](https://www.docker.com/)
- [Alpine Linux](https://www.alpinelinux.org/)
- [OpenSSH](https://www.openssh.com/)
- [rsync](https://rsync.samba.org/)

Refer to their respective licenses for details.

## 📜 License

This project is licensed under the **[MIT License](https://github.com/RipleyBooya/DVDBR/blob/main/LICENSE)** – free to use, modify, and distribute with attribution.

## 🤖 AI Assistance & Acknowledgment

This project was developed with assistance from an AI-powered assistant, ensuring efficiency and optimization while maintaining human oversight.

## 🔗 Project Links & Contributions

- 🛠 **Source Code & Issues:** [GitHub Repository](https://github.com/RipleyBooya/DVDBR)  
- 🇫🇷 **Version française (WikiJS):** [ltgs.wiki (FR)](https://ltgs.wiki/fr/InfoTech/Virt/Docker/DVDBR) 
- 🇺🇸 **English version (WikiJS):** [ltgs.wiki (EN)](https://ltgs.wiki/en/InfoTech/Virt/Docker/DVDBR) 

If you find any issues or have suggestions, feel free to **open a GitHub issue or contribute!** 🚀
