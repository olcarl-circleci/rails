packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3.0"
    }
  }
}

variable "region" {
  default = "us-west-2"
}

# Buildkite Elastic CI Stack AL2023 x86_64 AMI, plus the system libs the Rails
# native gems need at build time (libxml-ruby -> libxml2). most_recent tracks
# Buildkite's base as they republish it, so a re-bake is just `packer build`.
source "amazon-ebs" "buildkite" {
  region        = var.region
  instance_type = "t3.small"

  source_ami_filter {
    filters = {
      name                = "buildkite-stack-linux-amazonlinux2023-x86_64-*"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["172840064832"]
    most_recent = true
  }

  # Connect over SSM so no inbound SSH / public ingress is needed.
  communicator         = "ssh"
  ssh_username         = "ec2-user"
  ssh_interface        = "session_manager"
  iam_instance_profile = "packer-ami-builder"

  ami_name        = "buildkite-al2023-libxml2-{{timestamp}}"
  ami_description = "Buildkite Elastic CI Stack AL2023 + libxml2-devel for libxml-ruby"

  tags = {
    Name    = "buildkite-al2023-libxml2"
    BaseAMI = "{{ .SourceAMI }}"
    Purpose = "rails-ci-libxml-ruby"
  }
}

build {
  sources = ["source.amazon-ebs.buildkite"]

  provisioner "shell" {
    inline = [
      "sudo dnf install -y libxml2-devel pkgconf-pkg-config",
      "rpm -q libxml2-devel",
    ]
  }
}
