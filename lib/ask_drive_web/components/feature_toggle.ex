defmodule AskDriveWeb.FeatureToggle do
  @moduledoc """
  The on/off switch of a feature on the admin screens (spec F-206): switching takes effect at
  once (`phx-click="toggle_feature"`, handled by `AskDriveWeb.AdminLive`), separately from the
  feature's settings, whose 「保存」 only saves values and never turns anything on or off.
  Turning a feature on checks there and then that its saved settings are complete; what is
  missing is shown in the flash.
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :feature, :string, required: true
  attr :on, :boolean, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil, doc: "a line under the label (what switching does)"
  attr :confirm_on, :string, default: nil
  attr :confirm_off, :string, default: nil
  attr :disabled, :boolean, default: false

  def toggle(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-4 py-1">
      <div class="min-w-0">
        <p class="text-sm font-medium text-zinc-800 dark:text-zinc-200">{@label}</p>
        <p :if={@hint} class="text-[11px] text-zinc-500 leading-relaxed mt-0.5">{@hint}</p>
      </div>
      <div class="flex items-center gap-2 shrink-0">
        <span class={[
          "text-[11px] font-medium",
          if(@on, do: "text-emerald-700 dark:text-emerald-300", else: "text-zinc-500")
        ]}>
          {if @on, do: "有効", else: "無効"}
        </span>
        <button
          type="button"
          id={@id}
          role="switch"
          aria-checked={to_string(@on)}
          aria-label={@label}
          phx-click="toggle_feature"
          phx-value-feature={@feature}
          phx-value-on={to_string(!@on)}
          data-confirm={if(@on, do: @confirm_off, else: @confirm_on)}
          disabled={@disabled}
          class={[
            "relative inline-flex h-6 w-11 items-center rounded-full transition-colors duration-200",
            "focus:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500 focus-visible:ring-offset-2",
            "disabled:opacity-40 disabled:cursor-not-allowed",
            if(@on, do: "bg-emerald-500", else: "bg-zinc-300 dark:bg-zinc-700")
          ]}
        >
          <span class={[
            "inline-block h-5 w-5 rounded-full bg-white shadow transform transition-transform duration-200",
            if(@on, do: "translate-x-5", else: "translate-x-0.5")
          ]} />
        </button>
      </div>
    </div>
    """
  end
end
