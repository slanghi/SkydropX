#main.tf
#variables definitions
variable "key_name" {
  description = "Desired name of AWS key pair"
  default= "slanghi.pem"
}

variable "public_key_path"{
    description = "Path to the SSH public key to be used for authentication."
    default = "~/.ssh/id_rsa.pub"
}

variable "aws_region" {
  description = "AWS region to launch servers."
  default     = "us-east-1"
}

#VPC and subnets definitions
provider "aws" {  
    region = var.aws_region
    shared_credentials_file = "~/.aws/credentials"
    }

#Main VPC
resource "aws_vpc" "main" {

    cidr_block       = "10.0.0.0/16"
    enable_dns_hostnames = true
    instance_tenancy = "default"
    tags = {
        Name = "main"
  }
}

#Internet Gateway
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "Internet-Gateway"
  }
}

# Grant the VPC internet access on its main route table
resource "aws_route" "internet_access" {
  route_table_id         = "${aws_vpc.main.main_route_table_id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.gw.id}"
}


#Private Subnet
resource "aws_subnet" "private" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.1.0/24"

  tags = {
    Name = "private"
 }
 availability_zone="us-east-1a"
}
#############################################################################
#Resoruces for NAT

resource "aws_nat_gateway" "natgw" {
  allocation_id = "${aws_eip.nat.id}"
  subnet_id     = "${aws_subnet.public1a.id}"
}

resource "aws_eip" "nat" {
  vpc      = true
}


resource "aws_route_table" "nat" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.natgw.id
  }
}


resource "aws_route_table_association" "nat" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.nat.id
}



###############################################################################
#Public subnets
resource "aws_subnet" "public1a" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.5.0/24"
  tags = {
    Name = "public-us-east-1a"
 }
  availability_zone="us-east-1a"
}

resource "aws_subnet" "public1b" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.6.0/24"
  tags = {
    Name = "public-us-east-1b"
 }
  availability_zone="us-east-1b"
}




# A security group for the LB so it is accessible via the web
resource "aws_security_group" "alb" {
  name        = "security_group_alb"
  description = "Security group for the LB"
  vpc_id      = "${aws_vpc.main.id}"

  # HTTP access from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  
  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Default security group to access the instances over SSH and HTTP
resource "aws_security_group" "default" {
  name        = "security-group-EC2"
  description = "Security group for EC2 instances"
  vpc_id      = "${aws_vpc.main.id}"

  
    ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#ASG and LB definitions

resource "aws_lb" "loadbalancer" {
  name               = "Load-Balancer"
  internal           = false
  load_balancer_type = "application"

  subnets         = ["${aws_subnet.public1a.id}","${aws_subnet.public1b.id}"]
  security_groups = ["${aws_security_group.alb.id}"]
  
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.loadbalancer.arn
  port              = "80"
  protocol          = "HTTP"
  
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.lb-tg.arn
  }
}

resource "aws_lb_target_group" "lb-tg" {
  name     = "lb-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    interval            = 30
    path                = "/"
    port                = 80
    healthy_threshold   = 2
    unhealthy_threshold = 5
    timeout             = 5
    protocol            = "HTTP"
    matcher             = "200,202"
  }
}

resource "aws_launch_configuration" "web" {
  name_prefix = "web-"

  image_id = "ami-04505e74c0741db8d" # Amazon Ubuntu Server 20.04 (HVM), SSD Volume Type
  instance_type = "t2.micro"
  key_name = var.key_name

  security_groups = [ aws_security_group.default.id ]
  #associate_public_ip_address = true

  user_data = <<EOF
#!/bin/bash
sleep 10m
sudo apt-get update
sudo apt-get install nginx -y
sudo systemctl start nginx
sudo systemctl enable nginx
    EOF
  #depends_on = [aws_route.internet_access]
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "webasg" {
  name = "${aws_launch_configuration.web.name}-asg"

  min_size             = 1
  desired_capacity     = 2
  max_size             = 2
  
  
  health_check_type    = "EC2"  
  target_group_arns    = ["${aws_lb_target_group.lb-tg.arn}"]
  launch_configuration = aws_launch_configuration.web.name

  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupTotalInstances"
  ]

  metrics_granularity = "1Minute"
  vpc_zone_identifier  = [aws_subnet.private.id]

  # Required to redeploy without an outage.
  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "web"
    propagate_at_launch = true
  }

}

#Keys for EC2 access
resource "aws_key_pair" "auth" {
  key_name   = "${var.key_name}"
  public_key = "${file(var.public_key_path)}"
  }

#Autoscaling policies
resource "aws_autoscaling_policy" "autopolicy" {
name = "terraform-autoplicy"
scaling_adjustment = 1
adjustment_type = "ChangeInCapacity"
cooldown = 300
autoscaling_group_name = "${aws_autoscaling_group.webasg.name}"
}

resource "aws_cloudwatch_metric_alarm" "cpualarm" {
alarm_name = "terraform-alarm"
comparison_operator = "GreaterThanOrEqualToThreshold"
evaluation_periods = "2"
metric_name = "CPUUtilization"
namespace = "AWS/EC2"
period = "120"
statistic = "Average"
threshold = "40"


dimensions={AutoScalingGroupName = "${aws_autoscaling_group.webasg.name}"}

alarm_description = "Scale in EC2 instance cpu utilization"
alarm_actions = ["${aws_autoscaling_policy.autopolicy.arn}"]
}

#
resource "aws_autoscaling_policy" "autopolicy-down" {
name = "terraform-autoplicy-down"
scaling_adjustment = -1
adjustment_type = "ChangeInCapacity"
cooldown = 300
autoscaling_group_name = "${aws_autoscaling_group.webasg.name}"
}

resource "aws_cloudwatch_metric_alarm" "cpualarm-down" {
alarm_name = "terraform-alarm-down"
comparison_operator = "LessThanOrEqualToThreshold"
evaluation_periods = "2"
metric_name = "CPUUtilization"
namespace = "AWS/EC2"
period = "120"
statistic = "Average"
threshold = "20"

dimensions={AutoScalingGroupName = "${aws_autoscaling_group.webasg.name}"}

alarm_description = "Scale out EC2 instance cpu utilization"
alarm_actions = ["${aws_autoscaling_policy.autopolicy-down.arn}"]
}

#DNS name for the LB
output "lb_dns_name" {
  value = aws_lb.loadbalancer.dns_name
}