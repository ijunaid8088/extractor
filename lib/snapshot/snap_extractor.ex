defmodule Extractor.SnapExtractor do
  require IEx

  @evercam_api_url System.get_env["EVERCAM_URL"]
  @user_key System.get_env["USER_KEY"]
  @user_id System.get_env["USER_ID"]

  def fetch_dates_unix do
    extractor = SnapshotExtractor.fetch_details
    schedule = extractor.schedule
    interval = extractor.interval
    camera_exid = extractor.camera_exid

    timezone =
      case extractor.timezone do
        nil -> "Etc/UTC"
        _ -> extractor.timezone
      end

    start_date =
      extractor.from_date
      |> Ecto.DateTime.to_erl
      |> Calendar.DateTime.from_erl!(timezone)

    end_date =
      extractor.to_date
      |> Ecto.DateTime.to_erl
      |> Calendar.DateTime.from_erl!(timezone)

    total_days = find_difference(end_date, start_date) / 86400 |> round |> round_2

    1..total_days |> Enum.reduce(start_date, fn _i, acc ->
      day_of_week = acc |> Calendar.Date.day_of_week_name
      iterate(schedule[day_of_week], start_date, timezone) |> download(camera_exid)
      acc |> Calendar.DateTime.to_erl |> Calendar.DateTime.from_erl!(timezone, {123456, 6}) |> Calendar.DateTime.add!(86400)
    end)
  end

  def download([], _camera_exid), do: IO.inspect "I am empty!"
  def download([starting, ending], camera_exid) do
    starting..ending |> Enum.each(fn(day) ->
      url = "#{System.get_env["EVERCAM_URL"]}/#{camera_exid}/recordings/snapshots/#{day}?with_data=true&range=2&api_id=#{System.get_env["USER_ID"]}&api_key=#{System.get_env["USER_KEY"]}&notes=Evercam+Proxy"
      response = HTTPoison.get(url, [], []) |> elem(1)
      upload(response.status_code, response.body)
    end)
  end

  def upload(200, response) do
    IO.inspect response
  end
  def upload(_, response), do: IO.inspect "Not an Image!"

  defp find_difference(end_date, start_date) do
    case Calendar.DateTime.diff(end_date, start_date) do
      {:ok, seconds, _, :after} -> seconds
      _ -> 1
    end
  end

  def iterate([], _check_time, _timezone) do
    []
  end
  def iterate([head|_tail], check_time, timezone) do
    [from, to] = String.split head, "-"
    [from_hour, from_minute] = String.split from, ":"
    [to_hour, to_minute] = String.split to, ":"

    from_unix_timestamp = unix_timestamp(from_hour, from_minute, check_time, timezone)
    to_unix_timestamp = unix_timestamp(to_hour, to_minute, check_time, timezone)
    [from_unix_timestamp, to_unix_timestamp]
  end

  defp unix_timestamp(hours, minutes, date, nil) do
    unix_timestamp(hours, minutes, date, "UTC")
  end
  defp unix_timestamp(hours, minutes, date, timezone) do
    %{year: year, month: month, day: day} = date
    {h, _} = Integer.parse(hours)
    {m, _} = Integer.parse(minutes)
    erl_date_time = {{year, month, day}, {h, m, 0}}
    case Calendar.DateTime.from_erl(erl_date_time, timezone) do
      {:ok, datetime} -> datetime |> Calendar.DateTime.Format.unix
      {:ambiguous, datetime} -> datetime.possible_date_times |> hd |> Calendar.DateTime.Format.unix
      _ -> raise "Timezone conversion error"
    end
  end

  defp round_2(0), do: 2
  defp round_2(n), do: n
    
end