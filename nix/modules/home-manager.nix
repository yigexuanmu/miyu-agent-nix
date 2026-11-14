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

    daemon.enable = lib.mkEnableOption "miyu daemon 作为 systemd 用户服务常驻";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    systemd.user.services.miyu = lib.mkIf cfg.daemon.enable {
      Unit = {
        Description = "Miyu AI assistant daemon";
        After = [ "default.target" ];
      };
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${cfg.package}/bin/miyu daemon start";
        ExecStop = "${cfg.package}/bin/miyu daemon stop";
        TimeoutStartSec = 120;
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
