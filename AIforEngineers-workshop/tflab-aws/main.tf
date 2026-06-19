terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_ami" "windows" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  common_tags = {
    owner       = "training"
    participant = var.participant_name
  }
}

resource "aws_vpc" "lab" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "vpc-ailab-${var.participant_name}"
  })
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id

  tags = merge(local.common_tags, {
    Name = "igw-ailab-${var.participant_name}"
  })
}

resource "aws_subnet" "access" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.0.0.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "subnet-access"
  })
}

resource "aws_subnet" "app" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = merge(local.common_tags, {
    Name = "subnet-app"
  })
}

resource "aws_subnet" "db" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = merge(local.common_tags, {
    Name = "subnet-db"
  })
}

resource "aws_subnet" "win" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = merge(local.common_tags, {
    Name = "subnet-win"
  })
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "eip-nat"
  })
}

resource "aws_nat_gateway" "lab" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.access.id

  tags = merge(local.common_tags, {
    Name = "nat-ailab-${var.participant_name}"
  })

  depends_on = [aws_internet_gateway.lab]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = merge(local.common_tags, {
    Name = "rt-public"
  })
}

resource "aws_route_table_association" "access" {
  subnet_id      = aws_subnet.access.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.lab.id
  }

  tags = merge(local.common_tags, {
    Name = "rt-private"
  })
}

resource "aws_route_table_association" "app" {
  subnet_id      = aws_subnet.app.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "db" {
  subnet_id      = aws_subnet.db.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "win" {
  subnet_id      = aws_subnet.win.id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "eic_endpoint" {
  name        = "sg-eic-endpoint-${var.participant_name}"
  description = "Security group for EC2 Instance Connect Endpoint"
  vpc_id      = aws_vpc.lab.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "sg-eic-endpoint"
  })
}

resource "aws_ec2_instance_connect_endpoint" "lab" {
  subnet_id          = aws_subnet.access.id
  security_group_ids = [aws_security_group.eic_endpoint.id]
  preserve_client_ip = true

  tags = merge(local.common_tags, {
    Name = "eice-ailab-${var.participant_name}"
  })
}

resource "aws_security_group" "app" {
  name        = "sg-app-${var.participant_name}"
  description = "App instance security group"
  vpc_id      = aws_vpc.lab.id

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.eic_endpoint.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "sg-app"
  })
}

resource "aws_security_group" "db" {
  name        = "sg-db-${var.participant_name}"
  description = "Database instance security group"
  vpc_id      = aws_vpc.lab.id

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.eic_endpoint.id]
  }

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "sg-db"
  })
}

resource "aws_security_group" "win" {
  name        = "sg-win-${var.participant_name}"
  description = "Windows instance security group managed by SSM"
  vpc_id      = aws_vpc.lab.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "sg-win"
  })
}

resource "aws_iam_role" "ec2_ssm" {
  name = "role-ec2-ssm-${var.participant_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "profile-ec2-ssm-${var.participant_name}"
  role = aws_iam_role.ec2_ssm.name
}

resource "aws_instance" "app" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.large"
  subnet_id                   = aws_subnet.app.id
  private_ip                  = "10.0.1.10"
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_ssm.name
  associate_public_ip_address = false

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = merge(local.common_tags, {
    Name = "vm-app"
  })
}

resource "aws_instance" "db" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.large"
  subnet_id                   = aws_subnet.db.id
  private_ip                  = "10.0.2.10"
  vpc_security_group_ids      = [aws_security_group.db.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_ssm.name
  associate_public_ip_address = false
  user_data                   = templatefile("${path.module}/cloud-init-db.yaml", { db_password = var.admin_password })

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = merge(local.common_tags, {
    Name = "vm-db"
  })
}

resource "aws_instance" "win" {
  ami                         = data.aws_ami.windows.id
  instance_type               = "t3.medium"
  subnet_id                   = aws_subnet.win.id
  private_ip                  = "10.0.3.10"
  vpc_security_group_ids      = [aws_security_group.win.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_ssm.name
  associate_public_ip_address = false

  root_block_device {
    volume_type = "gp3"
    volume_size = 128
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = merge(local.common_tags, {
    Name = "vm-win"
  })
}
