export function StaleDataBanner({ message }: { message: string }) {
  return (
    <div className="rounded-lg border border-warning/20 bg-warning/10 px-4 py-3 text-sm text-warning">
      {message}
    </div>
  );
}
