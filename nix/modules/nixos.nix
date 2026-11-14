{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.miyu;
  defaultPackage =
    self.packages.${pkgs.stdenv.hostPlatform.system}.default
      or (throw "miyu-agent-nix 不支持 ${pkgs.stdenv.hostPlatform.system}");
in
{
  options.programs.miyu = {
    enable = lib.mkEnableOption "Miyu（终端 AI 助手）";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "miyu-agent-nix.packages.\${system}.default";
      description = "要安装的 miyu 包。";
    };

    daemon.enable = lib.mkEnableOption ''
      miyu daemon 作为 systemd 用户服务常驻（WebUI、平台接入、定时闹钟依赖它）
    '';
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # 上游 `miyu daemon start` 自己 daemonize 并写 lock 文件，所以这里是
    # oneshot + RemainAfterExit：systemd 只负责开机拉起、关机停掉。
    # 进程崩掉不会自动重启（上游没有前台模式），需要自愈的话自己加 timer。
    systemd.user.services.miyu = lib.mkIf cfg.daemon.enable {
      description = "Miyu AI assistant daemon";
      wantedBy = [ "default.target" ];
      after = [ "default.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${cfg.package}/bin/miyu daemon start";
        ExecStop = "${cfg.package}/bin/miyu daemon stop";
        TimeoutStartSec = 120;
      };
    };
  };
}
