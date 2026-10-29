import argparse
import json
import os
import pathlib
from typing import Callable, Optional

from stable_baselines3 import PPO
from stable_baselines3.common.callbacks import BaseCallback, CheckpointCallback
from stable_baselines3.common.vec_env.vec_monitor import VecMonitor

from godot_rl.core.utils import can_import
from godot_rl.wrappers.onnx.stable_baselines_export import export_model_as_onnx
from godot_rl.wrappers.stable_baselines_wrapper import StableBaselinesGodotEnv

if can_import("ray"):
    print("WARNING, stable baselines and ray[rllib] are not compatible")


class LevelExportCallback(BaseCallback):
    """
    Callback para monitorar o progresso do DragonDragonFireFire por fases (levels),
    permitindo exportar checkpoints ONNX em intervalos configurados e parar ao atingir o nível alvo.
    """

    def __init__(
        self,
        export_dir: str,
        target_level: Optional[int] = None,
        export_level_interval: Optional[int] = None,
        verbose: int = 0,
    ):
        super().__init__(verbose)
        self.export_dir = export_dir
        self.target_level = target_level
        self.export_level_interval = export_level_interval

        self.max_level_reached = 0
        self.last_exported_milestone = 0

        os.makedirs(self.export_dir, exist_ok=True)

    def _on_step(self) -> bool:
        infos = self.locals.get("infos", [])

        for info in infos:
            current_level = 0
            
            if isinstance(info, dict):
                if "level" in info:
                    current_level = info["level"]
                elif "current_level" in info:
                    current_level = info["current_level"]
                elif "diagnostic_data" in info and isinstance(info["diagnostic_data"], dict):
                    current_level = info["diagnostic_data"].get("level", 0)
            elif isinstance(info, (list, tuple)) and len(info) > 0:
                for item in info:
                    if isinstance(item, dict) and "level" in item:
                        current_level = item["level"]
                        break

            should_export = False
            should_stop = False

            if current_level > self.max_level_reached:
                print(f"[Callback] Novo recorde de fase alcançado: Nível {current_level}")

                if self.export_level_interval and self.export_level_interval > 0:
                    current_milestone = (
                        current_level // self.export_level_interval
                    ) * self.export_level_interval

                    if (
                        current_milestone > self.last_exported_milestone
                        and current_milestone > 0
                    ):
                        should_export = True
                        self.last_exported_milestone = current_milestone

                self.max_level_reached = current_level

            if (
                self.target_level
                and self.target_level > 0
                and current_level >= self.target_level
            ):
                if current_level >= self.max_level_reached:
                    should_export = True
                should_stop = True

            if should_export:
                self._export_onnx_and_metrics(current_level)

            if should_stop:
                print(
                    f"\n[Callback] Meta de nível {current_level}/{self.target_level} alcançada. Parando treinamento!"
                )
                return False

        return True

    def _export_onnx_and_metrics(self, level_count: int):
        onnx_filename = os.path.join(
            self.export_dir, f"model_level_{level_count}.onnx"
        )
        print(
            f"\n[Callback] Exportando ONNX para {onnx_filename} (Nível {level_count})..."
        )
        export_model_as_onnx(self.model, onnx_filename)

        metrics = {
            "best_level_reached": level_count,
            "timesteps": self.num_timesteps,
            "n_updates": getattr(self.model, "_n_updates", 0),
        }

        if hasattr(self.model, "logger") and self.model.logger:
            for k, v in self.model.logger.name_to_value.items():
                metrics[k] = float(v)

        metrics_filename = os.path.join(
            self.export_dir, f"metrics_level_{level_count}.json"
        )
        with open(metrics_filename, "w") as f:
            json.dump(metrics, f, indent=4)
        print(f"[Callback] Métricas salvas em {metrics_filename}")


parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument("--env_path", default=None, type=str)
parser.add_argument("--experiment_dir", default="logs/sb3", type=str)
parser.add_argument("--experiment_name", default="dragon_experiment", type=str)
parser.add_argument("--seed", type=int, default=0)
parser.add_argument("--resume_model_path", default=None, type=str)
parser.add_argument("--save_model_path", default=None, type=str)
parser.add_argument("--save_checkpoint_frequency", default=None, type=int)
parser.add_argument("--onnx_export_path", default=None, type=str)
parser.add_argument("--timesteps", default=1_000_000, type=int)
parser.add_argument("--inference", action="store_true", default=False)
parser.add_argument("--linear_lr_schedule", action="store_true", default=False)
parser.add_argument("--viz", action="store_true", default=False)
parser.add_argument("--speedup", default=1, type=int)
parser.add_argument("--n_parallel", default=1, type=int)

# Argumentos específicos para controle por fases no DragonDragonFireFire
parser.add_argument(
    "--target_level",
    default=None,
    type=int,
    help="Nível do jogo (fase) alvo para encerrar o treino automaticamente (Opcional).",
)
parser.add_argument(
    "--export_level_interval",
    default=None,
    type=int,
    help="Intervalo de fases concluídas para exportar ONNX e métricas intermediárias (Opcional).",
)

args, extras = parser.parse_known_args()


def handle_onnx_export():
    if args.onnx_export_path is not None:
        path_onnx = pathlib.Path(args.onnx_export_path).with_suffix(".onnx")
        print("Exporting final onnx to: " + os.path.abspath(path_onnx))
        export_model_as_onnx(model, str(path_onnx))


def handle_model_save():
    if args.save_model_path is not None:
        zip_save_path = pathlib.Path(args.save_model_path).with_suffix(".zip")
        print("Saving model to: " + os.path.abspath(zip_save_path))
        model.save(zip_save_path)


def close_env():
    try:
        print("closing env")
        env.close()
    except Exception as e:
        print("Exception while closing env: ", e)


def cleanup():
    handle_onnx_export()
    handle_model_save()
    close_env()


path_checkpoint = os.path.join(
    args.experiment_dir, args.experiment_name + "_checkpoints"
)
abs_path_checkpoint = os.path.abspath(path_checkpoint)

if args.save_checkpoint_frequency is not None and os.path.isdir(path_checkpoint):
    raise RuntimeError(abs_path_checkpoint + " folder already exists.")

if args.inference and args.resume_model_path is None:
    raise parser.error("Using --inference requires --resume_model_path to be set.")

env = StableBaselinesGodotEnv(
    env_path=args.env_path,
    show_window=args.viz,
    seed=args.seed,
    n_parallel=args.n_parallel,
    speedup=args.speedup,
)
env = VecMonitor(env)


def linear_schedule(initial_value: float) -> Callable[[float], float]:
    def func(progress_remaining: float) -> float:
        return progress_remaining * initial_value

    return func


if args.resume_model_path is None:
    learning_rate = (
        0.0003 if not args.linear_lr_schedule else linear_schedule(0.0003)
    )
    model: PPO = PPO(
        "MultiInputPolicy",
        env,
        ent_coef=0.0001,
        verbose=2,
        n_steps=32,
        tensorboard_log=args.experiment_dir,
        learning_rate=learning_rate,
    )
else:
    path_zip = pathlib.Path(args.resume_model_path)
    print("Loading model: " + os.path.abspath(path_zip))
    model = PPO.load(path_zip, env=env, tensorboard_log=args.experiment_dir)

if args.inference:
    obs = env.reset()
    for i in range(args.timesteps):
        action, _state = model.predict(obs, deterministic=True)
        obs, reward, done, info = env.step(action)
else:
    callbacks = []

    if args.save_checkpoint_frequency:
        callbacks.append(
            CheckpointCallback(
                save_freq=(args.save_checkpoint_frequency // env.num_envs),
                save_path=path_checkpoint,
                name_prefix=args.experiment_name,
            )
        )

    if args.target_level is not None or args.export_level_interval is not None:
        level_callback = LevelExportCallback(
            export_dir=os.path.join(args.experiment_dir, "onnx_exports"),
            target_level=args.target_level,
            export_level_interval=args.export_level_interval,
        )
        callbacks.append(level_callback)

    learn_arguments = dict(
        total_timesteps=args.timesteps,
        tb_log_name=args.experiment_name,
        callback=callbacks,
    )

    try:
        model.learn(**learn_arguments)
    except (KeyboardInterrupt, ConnectionError, ConnectionResetError):
        print("Training interrupted.")
    finally:
        cleanup()