import paramiko
import getpass
import logging

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

def automate_server_setup(hostname, username, password):
    try:
        # Create an SSH client
        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        
        # Connect to the remote server
        ssh.connect(hostname, username=username, password=password)
        logging.info(f"Connected to {hostname} as {username}.")
        
        # Commands to execute on the remote server
        commands = [
            # Update the system
            'apt-get update',
            'apt-get install -y curl sudo mc git ca-certificates gnupg',
            
            # Add user 'mareox' with a secure password
            'useradd -m -s /bin/bash mareox',
            f'echo "mareox:{password}" | chpasswd',
            
            # Add 'mareox' to the sudo group
            'usermod -aG sudo mareox',
            
            # Allow 'mareox' to run sudo commands without a password
            'echo "mareox ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers',
            
            # Create the /etc/scripts directory
            'mkdir -p /etc/scripts',
            
            # Create a bash script in /etc/scripts
            'echo \'#!/bin/bash\nbash <(curl -s https://raw.githubusercontent.com/mareox/linux_scripts/main/nosudo-update.sh) install\' > /etc/scripts/update.sh',
            
            # Create a script to reset the machine-id
            'echo \'sudo rm -f /etc/machine-id\nsudo rm -f /var/lib/dbus/machine-id\' > /etc/scripts/reset-machine-id.sh',

            # Make the script executable
            'chmod +x /etc/scripts/*.sh',
            
            # Function to check if alias exists
            'check_alias() { grep -qFx "alias update=\\"$1\\"" $2 || echo "$1" >> $2; }',
            
            # Add alias 'update' to mareox's .bashrc if it doesn't exist
            'check_alias \'alias update="sudo bash /etc/scripts/update.sh"\' /home/mareox/.bashrc',
            
            # Add alias 'update' to root's .bashrc if it doesn't exist
            'check_alias \'alias update="/etc/scripts/update.sh"\' /root/.bashrc',

            # Run the update command
            'bash /etc/scripts/update.sh',

            # Ensure the .ssh directory exists for mareox
            'mkdir -p /home/mareox/.ssh',
            'chmod 700 /home/mareox/.ssh',

            # Add the public key to authorized_keys
            f'echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCvfUBTA4oN0qiPpfUzDzDaEL1YtiivMQA2XhwFCaP0FlH2JYw9YTYaicDRLrHU29TmA5N1S+aMxrM+e2i7lN61DxVIJxK68uvEpIk9RDlhRByDWLUou9IDQqbYTNQ9nkYuYWrBi4qtxBLR6Jxa+vKF5LBc5EziLSx8+cE89Tt7Yu7KyF1GpYu0MhHA1dxGA/YDp5gasSDXm6GBNgCr/bJ4smU7GFZCnAZAvLToue80NVqqYoMsDJ2QYhxy8ITitHDjRO/ZJmm2LXMWaAf8zbRUn1u93+gIIyJZHnw2trucY3PN6BlZqdzp30PCDfLnRdi1vEx57fQqWkelr3zpPVUr mareox-key" >> /home/mareox/.ssh/authorized_keys',
            'chmod 600 /home/mareox/.ssh/authorized_keys',

            # Set ownership of .ssh directory and files to mareox
            'chown -R mareox:mareox /home/mareox/.ssh',
        ]
        
        # Execute each command with real-time output
        for command in commands:
            logging.info(f"Executing command: {command}")
            stdin, stdout, stderr = ssh.exec_command(command)
            
            # Read output and errors in real-time
            while True:
                # Read stdout
                output = stdout.readline()
                if output:
                    logging.info(output.strip())
                
                # Read stderr
                error = stderr.readline()
                if error:
                    logging.error(error.strip())
                
                # Break the loop if the command has finished
                if not output and not error:
                    break
        
        logging.info(f"Setup completed successfully on {hostname}.")
    
    except Exception as e:
        logging.error(f"An error occurred: {e}")
    
    finally:
        # Close the SSH connection
        ssh.close()
        logging.info("SSH connection closed.")

if __name__ == "__main__":
    # Get the IP address of the remote server
    hostname = input("Enter the IP address of the new host: ")
    
    # Get the root user's password
    password = getpass.getpass("Enter the root password: ")
    
    # Get the public SSH key for mareox
    # public_key = input("Enter the public SSH key for mareox: ")
    
    # Run the automation script
    automate_server_setup(hostname, "root", password)
