terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-2" # Ohio, closest AWS region to Ann Arbor
}

variable "key_name" {
  description = "Existing EC2 key pair name"
  type        = string
}

variable "school_cidr" {
  description = "School building network range (VPN side)"
  type        = string
  default     = "10.50.0.0/16"
}

variable "windows_type" {
  type    = string
  default = "c5.xlarge" # 4 vCPU, 8 GB
}

variable "linux_type" {
  type    = string
  default = "c5.large" # 2 vCPU, 4 GB
}

locals {
  windows_servers = {
    dc1  = "10.20.2.10"
    dc2  = "10.20.2.11"
    msca = "10.20.2.20"
    nps  = "10.20.2.30"
  }
  linux_external = {
    ext-linux1 = "10.20.1.21"
    ext-linux2 = "10.20.1.22"
  }
  linux_internal = {
    int-linux1 = "10.20.2.41"
    int-linux2 = "10.20.2.42"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "windows" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# ---------- Network ----------
resource "aws_vpc" "school" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "school-vpc" }
}

resource "aws_subnet" "external" {
  vpc_id                  = aws_vpc.school.id
  cidr_block              = "10.20.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "external-subnet" }
}

resource "aws_subnet" "internal" {
  vpc_id            = aws_vpc.school.id
  cidr_block        = "10.20.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "internal-subnet" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.school.id
  tags   = { Name = "school-igw" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.external.id
  depends_on    = [aws_internet_gateway.igw]
  tags          = { Name = "school-nat" }
}

resource "aws_route_table" "external" {
  vpc_id = aws_vpc.school.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "external-rt" }
}

resource "aws_route_table" "internal" {
  vpc_id = aws_vpc.school.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  # Add after the virtual firewall exists:
  # route {
  #   cidr_block           = var.school_cidr
  #   network_interface_id = "<firewall-eni-id>"
  # }
  tags = { Name = "internal-rt" }
}

resource "aws_route_table_association" "external" {
  subnet_id      = aws_subnet.external.id
  route_table_id = aws_route_table.external.id
}

resource "aws_route_table_association" "internal" {
  subnet_id      = aws_subnet.internal.id
  route_table_id = aws_route_table.internal.id
}

# ---------- Security groups ----------
resource "aws_security_group" "external_linux" {
  name   = "external-linux-sg"
  vpc_id = aws_vpc.school.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.school_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "internal_linux" {
  name   = "internal-linux-sg"
  vpc_id = aws_vpc.school.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.school_cidr]
  }
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.school.cidr_block]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "windows" {
  name   = "windows-sg"
  vpc_id = aws_vpc.school.id

  ingress {
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = [var.school_cidr]
  }
  # Traffic between servers in the internal subnet (AD replication, etc.)
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.20.2.0/24"]
  }
  # Domain services from the school network
  dynamic "ingress" {
    for_each = [
      { port = 53, proto = "tcp" },
      { port = 53, proto = "udp" },
      { port = 88, proto = "tcp" },
      { port = 88, proto = "udp" },
      { port = 389, proto = "tcp" },
      { port = 389, proto = "udp" },
      { port = 636, proto = "tcp" },
      { port = 445, proto = "tcp" },
      { port = 1812, proto = "udp" },
      { port = 1813, proto = "udp" },
    ]
    content {
      from_port   = ingress.value.port
      to_port     = ingress.value.port
      protocol    = ingress.value.proto
      cidr_blocks = [var.school_cidr]
    }
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------- Servers ----------
resource "aws_instance" "windows" {
  for_each               = local.windows_servers
  ami                    = data.aws_ami.windows.id
  instance_type          = var.windows_type
  subnet_id              = aws_subnet.internal.id
  private_ip             = each.value
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.windows.id]

  root_block_device {
    encrypted = true
  }
  tags = { Name = upper(each.key), Role = "windows" }
}

resource "aws_instance" "linux_external" {
  for_each               = local.linux_external
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.linux_type
  subnet_id              = aws_subnet.external.id
  private_ip             = each.value
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.external_linux.id]

  root_block_device {
    encrypted = true
  }
  tags = { Name = each.key, Role = "linux-external" }
}

resource "aws_instance" "linux_internal" {
  for_each               = local.linux_internal
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.linux_type
  subnet_id              = aws_subnet.internal.id
  private_ip             = each.value
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.internal_linux.id]

  root_block_device {
    encrypted = true
  }
  tags = { Name = each.key, Role = "linux-internal" }
}

# ---------- Outputs ----------
output "vpc_id" {
  value = aws_vpc.school.id
}

output "windows_private_ips" {
  value = { for k, v in aws_instance.windows : k => v.private_ip }
}

output "linux_external_ips" {
  value = { for k, v in aws_instance.linux_external : k => v.public_ip }
}

output "linux_internal_private_ips" {
  value = { for k, v in aws_instance.linux_internal : k => v.private_ip }
}
