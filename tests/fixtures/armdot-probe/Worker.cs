namespace Probe;

public static class Worker
{
    public static int Run(int limit) => Sum(limit);

    private static int Sum(int limit)
    {
        var total = 0;
        for (var i = 0; i < limit; i++)
        {
            if (i % 3 == 0) total += i;
            else total -= 1;
        }
        return total;
    }
}
