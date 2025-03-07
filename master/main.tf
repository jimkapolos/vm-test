terraform {
  required_providers {
    kubevirt = {
      source  = "kubevirt/kubevirt"
      version = "0.0.1"
    }
  }
}

provider "kubevirt" {
  config_context = "kubernetes-admin@kubernetes"
}

resource "kubevirt_virtual_machine" "github-action" {
  metadata {
    name      = "github-action"
    namespace = "default"
    annotations = {
      "kubevirt.io/domain" = "github-action"
    }
  }
  
  # Make sure to include the spec block as in your original configuration
  spec {
    run_strategy = "Always"
    data_volume_templates {
      metadata {
        name      = "ubuntu-disk4"
        namespace = "default"
      }
      spec {
        pvc {
          access_modes = ["ReadWriteOnce"]
          resources {
            requests = {
              storage = "10Gi"
            }
          }
        }
        source {
          http {
            url = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
          }
        }
      }
    }
    template {
      metadata {
        labels = {
          "kubevirt.io/domain" = "github-action"
        }
      }
      spec {
        domain {
          devices {
            disk {
              name = "rootdisk"
              disk_device {
                disk {
                  bus = "virtio"
                }
              }
            }
            disk {
              name = "cloudinitdisk"
              disk_device {
                disk {
                  bus = "virtio"
                }
              }
            }
            interface {
              name                     = "default"
              interface_binding_method = "InterfaceMasquerade"
            }
          }
          resources {
            requests = {
              cpu    = "2"
              memory = "2Gi"
            }
          }
        }
        network {
          name = "default"
          network_source {
            pod {}
          }
        }
        volume {
          name = "rootdisk"
          volume_source {
            data_volume {
              name = "ubuntu-disk4"
            }
          }
        }
        volume {
          name = "cloudinitdisk"
          volume_source {
            cloud_init_config_drive {
              user_data = <<EOF
#cloud-config
ssh_pwauth: true
users:
  - name: apel
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, admin
    shell: /bin/bash
    lock_passwd: false
chpasswd:
  list: |
    apel:apel1234
  expire: false
write_files:
  - path: /usr/local/bin/k3s-setup.sh
    permissions: "0755"
    content: |
      #!/bin/bash
      echo "apel ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
      sudo apt-get update
      sudo apt-get install -y bash-completion sshpass uidmap ufw
      echo "source <(kubectl completion bash)" >> ~/.bashrc
      echo "export KUBE_EDITOR=\"/usr/bin/nano\"" >> ~/.bashrc
      wget https://github.com/containerd/nerdctl/releases/download/v1.7.6/nerdctl-full-1.7.6-linux-amd64.tar.gz
      sudo tar Cxzvvf /usr/local nerdctl-full-1.7.6-linux-amd64.tar.gz
      cd /usr/local/bin && containerd-rootless-setuptool.sh install
      sudo ufw disable
      curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE="644" INSTALL_K3S_EXEC="--cluster-cidr=20.10.0.0/16" sh
      
  - path: /etc/systemd/system/k3s-setup.service
    permissions: "0644"
    content: |
      [Unit]
      Description=Setup K3s Master Node
      After=network.target
      Wants=network-online.target
      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/k3s-setup.sh
      RemainAfterExit=true
      [Install]
      WantedBy=multi-user.target
runcmd:
  - systemctl daemon-reload
  - systemctl enable k3s-setup.service
  - systemctl start k3s-setup.service
EOF
            }
          }
        }
      }
    }
  }
}

# Add the null_resource for getting the master information
resource "null_resource" "get_master_info" {
  depends_on = [kubevirt_virtual_machine.github-action]

  # This will run after the VM is created
  provisioner "local-exec" {
    command = <<-EOT
      # Wait for the VM to be ready
      echo "Waiting for VM to be ready..."
      kubectl wait --for=condition=Ready vm/github-action --timeout=300s
      
      # Wait a bit more for K3s to be fully initialized
      sleep 120
      
      # Get the VM IP
      VM_IP=$(kubectl get vmi github-action -o jsonpath='{.status.interfaces[0].ipAddress}')
      
      # Wait until SSH is available
      until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 apel@$VM_IP "echo SSH is up"; do
        echo "Waiting for SSH to be available..."
        sleep 10
      done
      
      # Get the K3s token
      K3S_TOKEN=$(ssh -o StrictHostKeyChecking=no apel@$VM_IP "sudo cat /var/lib/rancher/k3s/server/node-token")
      
      # Save the information to files that will be used by the output
      echo $VM_IP > vm_ip.txt
      echo $K3S_TOKEN > k3s_token.txt
    EOT
  }
}

# Read the IP and token from the files created by the null_resource
data "local_file" "vm_ip" {
  depends_on = [null_resource.get_master_info]
  filename   = "vm_ip.txt"
}

data "local_file" "k3s_token" {
  depends_on = [null_resource.get_master_info]
  filename   = "k3s_token.txt"
}

# Output the IP and token
output "master_ip" {
  value = trimspace(data.local_file.vm_ip.content)
}

output "k3s_token" {
  value     = trimspace(data.local_file.k3s_token.content)
  sensitive = true  # Mark as sensitive to prevent showing in logs
}
