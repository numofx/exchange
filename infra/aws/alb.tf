resource "aws_lb" "main" {
  name               = "${var.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  # /v1/ws carries the live order book. The 60s default would sever idle sockets and
  # look like flapping clients rather than an LB setting.
  idle_timeout = 3600

  enable_deletion_protection = true
  drop_invalid_header_fields = true

  tags = { Name = "${var.name}-alb" }
}

resource "aws_lb_target_group" "markets" {
  name        = "${var.name}-markets"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    path                = "/healthz"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  # Long enough to finish in-flight requests, short enough that a cutover rollback
  # is not waiting on drain.
  deregistration_delay = 30

  stickiness {
    type    = "lb_cookie"
    enabled = false
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.markets.arn
  }
}

# No :80 listener. Railway served this host over HTTPS only and the frontend has
# never issued a plaintext request to it; adding a redirect would create a
# downgrade path that does not exist today.
